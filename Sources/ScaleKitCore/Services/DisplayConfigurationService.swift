import Foundation

/// One row of the before/after summary shown before a change.
public struct ChangeRow: Sendable, Equatable, Identifiable {
    public var label: String
    public var before: String
    public var after: String

    public init(label: String, before: String, after: String) {
        self.label = label
        self.before = before
        self.after = after
    }

    public var id: String { label }
    public var changed: Bool { before != after }
}

/// Everything the user needs to see before a change is applied.
public struct ChangePlan: Sendable, Equatable {
    public var displayID: UInt32
    public var displayName: String
    public var from: DisplayModeInfo?
    public var to: DisplayModeInfo
    public var validation: ModeValidation
    public var refresh: RefreshComparison
    public var rows: [ChangeRow]

    public init(
        displayID: UInt32, displayName: String, from: DisplayModeInfo?, to: DisplayModeInfo,
        validation: ModeValidation, refresh: RefreshComparison, rows: [ChangeRow]
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.from = from
        self.to = to
        self.validation = validation
        self.refresh = refresh
        self.rows = rows
    }
}

/// What was observed after a mode change.
public struct ApplyVerification: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable {
        /// CoreGraphics reports the requested mode and AppKit agrees on scale and size.
        case verified
        /// CoreGraphics reports the requested mode; AppKit did not confirm it.
        case partial
        /// The active mode is not the requested one.
        case failed
    }

    public var level: Level
    public var requested: DisplayModeInfo
    public var observed: DisplayModeInfo?
    public var screenScale: Fact<Double>
    public var screenSize: Fact<PixelSize>
    /// Independent cross-check from `system_profiler`, when requested.
    public var secondary: Fact<String>
    public var notes: [String]
    public var elapsedSeconds: Double

    public init(
        level: Level, requested: DisplayModeInfo, observed: DisplayModeInfo?, screenScale: Fact<Double>,
        screenSize: Fact<PixelSize>, secondary: Fact<String>, notes: [String], elapsedSeconds: Double
    ) {
        self.level = level
        self.requested = requested
        self.observed = observed
        self.screenScale = screenScale
        self.screenSize = screenSize
        self.secondary = secondary
        self.notes = notes
        self.elapsedSeconds = elapsedSeconds
    }

    public var modeMatches: Bool { observed?.signature == requested.signature }
}

/// Pure comparison of a requested mode with what the system reports.
public enum VerificationEvaluator {
    public static func evaluate(
        requested: DisplayModeInfo, observed: DisplayModeInfo?, screen: ScreenSnapshot?
    ) -> (level: ApplyVerification.Level, notes: [String]) {
        guard let observed else {
            return (.failed, ["CoreGraphics returned no active mode for the display."])
        }
        guard observed.signature == requested.signature else {
            return (.failed, ["macOS reports \(observed.signature) instead of the requested \(requested.signature)."])
        }
        var notes = ["CoreGraphics reports \(observed.signature) (mode \(observed.modeID))."]
        guard let screen else {
            notes.append("AppKit has no screen for this display, so scale and size were not cross-checked.")
            return (.partial, notes)
        }
        let scaleMatches = abs(screen.backingScaleFactor - requested.scaleFactor) < 0.01
        let sizeMatches = screen.frame.size == requested.logical
        if scaleMatches && sizeMatches {
            notes.append("AppKit reports \(screen.frame.size) points at \(HiDPIStatus.format(screen.backingScaleFactor))× backing scale.")
            return (.verified, notes)
        }
        notes.append("AppKit reports \(screen.frame.size) points at \(HiDPIStatus.format(screen.backingScaleFactor))×, expected \(requested.logical) at \(HiDPIStatus.format(requested.scaleFactor))×.")
        return (.partial, notes)
    }
}

/// Plans, applies and verifies display mode changes.
///
/// This service never decides *whether* a change should happen; callers go
/// through `RecoveryService`, which handles backups and rollback.
@MainActor
public final class DisplayConfigurationService {
    public let hardware: DisplayHardware
    private let modes: DisplayModeService
    /// How long to wait for CoreGraphics and AppKit to report the new mode.
    public var verificationTimeout: Duration = .seconds(4)
    public var pollInterval: Duration = .milliseconds(100)
    /// Run `system_profiler` as an extra cross-check after applying.
    public var useSecondaryProbe = false

    public init(hardware: DisplayHardware, modes: DisplayModeService) {
        self.hardware = hardware
        self.modes = modes
    }

    public func plan(for display: DisplayInfo, target: DisplayModeInfo) -> ChangePlan {
        let available = modes.desktopModes(for: display.id)
        let native = display.nativeResolution.value
        let validation = ModeValidator.validate(
            target, available: available, current: display.currentMode, native: native)
        let from = display.currentMode
        let refresh = RefreshComparison.compare(from: from?.refreshRate ?? 0, to: target.refreshRate)

        func uiSize(_ mode: DisplayModeInfo?) -> String {
            guard let mode, let native else { return "—" }
            return "\(Int((RecommendationEngine.uiScale(of: mode, native: native) * 100).rounded()))%"
        }
        func output(_ mode: DisplayModeInfo?) -> String {
            guard let mode, let native else { return "—" }
            return mode.hasNativeFlag ? "\(native) (native)" : "Not reported"
        }
        func sharpness(_ mode: DisplayModeInfo?) -> String {
            guard let mode else { return "—" }
            return HiDPIDetection.renderingPath(for: mode, native: native).label
        }
        let rows = [
            ChangeRow(label: "Interface size", before: uiSize(from), after: uiSize(target)),
            ChangeRow(label: "Looks like", before: from.map { "\($0.logical)" } ?? "—", after: "\(target.logical)"),
            ChangeRow(label: "Rendered at", before: from.map { "\($0.pixels)" } ?? "—", after: "\(target.pixels)"),
            ChangeRow(label: "Physical output", before: output(from), after: output(target)),
            ChangeRow(label: "Text rendering", before: sharpness(from), after: sharpness(target)),
            ChangeRow(label: "Refresh rate", before: from?.refreshLabel ?? "—", after: target.refreshLabel),
            ChangeRow(label: "Aspect ratio", before: from?.logical.aspectLabel ?? "—", after: target.logical.aspectLabel),
        ]
        return ChangePlan(
            displayID: display.id, displayName: display.displayName, from: from, to: target,
            validation: validation, refresh: refresh, rows: rows)
    }

    /// Applies `target` and waits until the system reports it (or times out).
    public func apply(
        _ target: DisplayModeInfo, to displayID: UInt32, scope: ConfigurationScope
    ) async throws -> ApplyVerification {
        let started = ContinuousClock.now
        Log.configuration.notice(
            "Applying mode \(target.modeID) (\(target.summary, privacy: .public)) to display \(displayID), scope \(scope.rawValue, privacy: .public)")
        try hardware.applyMode(modeID: target.modeID, to: displayID, scope: scope)
        Log.configuration.notice("CoreGraphics accepted mode \(target.modeID) for display \(displayID); verifying")
        return await verify(target, on: displayID, since: started)
    }

    /// Reads the active mode back until it matches `target` and AppKit agrees,
    /// or until the timeout passes.
    public func verify(
        _ target: DisplayModeInfo, on displayID: UInt32, since started: ContinuousClock.Instant = .now
    ) async -> ApplyVerification {
        let clock = ContinuousClock()
        let deadline = started + verificationTimeout
        var observed = hardware.currentMode(for: displayID)
        var screen = hardware.screenSnapshots().first { $0.displayID == displayID }
        var result = VerificationEvaluator.evaluate(requested: target, observed: observed, screen: screen)

        while result.level != .verified && clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            observed = hardware.currentMode(for: displayID)
            screen = hardware.screenSnapshots().first { $0.displayID == displayID }
            result = VerificationEvaluator.evaluate(requested: target, observed: observed, screen: screen)
        }

        var secondary: Fact<String> = .unavailable("Secondary check not requested")
        if useSecondaryProbe {
            Log.configuration.notice("Running system_profiler cross-check for display \(displayID)")
            if let report = await SystemProfilerProbe.run(),
               let entry = report.first(where: { $0.displayID == displayID }) {
                secondary = .inferred(entry.summary, reason: "system_profiler SPDisplaysDataType (undocumented JSON keys)")
            } else {
                secondary = .unavailable("system_profiler did not report this display")
            }
        }

        let elapsed = started.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        Log.configuration.notice(
            "Verification for display \(displayID): \(result.level.rawValue, privacy: .public)")
        return ApplyVerification(
            level: result.level,
            requested: target,
            observed: observed,
            screenScale: screen.map { .measured($0.backingScaleFactor, source: "NSScreen.backingScaleFactor") }
                ?? .unavailable("AppKit has no screen for this display"),
            screenSize: screen.map { .measured($0.frame.size, source: "NSScreen.frame") }
                ?? .unavailable("AppKit has no screen for this display"),
            secondary: secondary,
            notes: result.notes,
            elapsedSeconds: seconds
        )
    }
}

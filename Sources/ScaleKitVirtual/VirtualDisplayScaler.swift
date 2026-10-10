import AppKit
import CoreGraphics
import ScaleKitCore
import ScaleKitVirtualBridge

/// What macOS reported after the monitor was mirrored to the virtual display.
public struct VirtualScalingVerification: Sendable, Equatable {
    /// The physical monitor mirrors the virtual display.
    public var mirrorActive: Bool
    /// The virtual display's active mode (CGDisplayCopyDisplayMode).
    public var virtualMode: DisplayModeInfo?
    /// AppKit's backing scale factor for the virtual display's screen.
    public var screenScale: Double?
    /// AppKit's size of that screen, in points.
    public var screenSize: PixelSize?
    /// The physical monitor's mode as CoreGraphics reports it while mirrored.
    public var physicalMode: DisplayModeInfo?
    public var notes: [String]
    public var elapsedSeconds: Double

    public init(
        mirrorActive: Bool, virtualMode: DisplayModeInfo?, screenScale: Double?, screenSize: PixelSize?,
        physicalMode: DisplayModeInfo?, notes: [String], elapsedSeconds: Double
    ) {
        self.mirrorActive = mirrorActive
        self.virtualMode = virtualMode
        self.screenScale = screenScale
        self.screenSize = screenSize
        self.physicalMode = physicalMode
        self.notes = notes
        self.elapsedSeconds = elapsedSeconds
    }

    /// Mirroring is on and both CoreGraphics and AppKit report the planned HiDPI desktop.
    public func isVerified(for plan: VirtualScalingPlan) -> Bool {
        mirrorActive
            && virtualMode?.logical == plan.points
            && virtualMode?.pixels == plan.pixels
            && screenScale.map { abs($0 - 2) < 0.01 } == true
    }

    /// The same result in the shape the trial panel already shows.
    public func applyVerification(for plan: VirtualScalingPlan) -> ApplyVerification {
        let level: ApplyVerification.Level =
            isVerified(for: plan) ? .verified
            : (mirrorActive && virtualMode?.pixels == plan.pixels ? .partial : .failed)
        return ApplyVerification(
            level: level,
            requested: plan.modeInfo,
            observed: virtualMode,
            screenScale: screenScale.map { .measured($0, source: "NSScreen.backingScaleFactor (virtual display)") }
                ?? .unavailable("AppKit has no screen for the virtual display"),
            screenSize: screenSize.map { .measured($0, source: "NSScreen.frame (virtual display)") }
                ?? .unavailable("AppKit has no screen for the virtual display"),
            secondary: physicalMode.map {
                .measured("Monitor mode while mirrored: \($0.summary)", source: "CGDisplayCopyDisplayMode")
            } ?? .unavailable("CoreGraphics reports no mode for the mirrored monitor"),
            notes: notes,
            elapsedSeconds: elapsedSeconds)
    }
}

public struct VirtualScalingSession: Sendable, Equatable {
    public var id: UUID
    public var plan: VirtualScalingPlan
    public var physicalID: UInt32
    public var physicalKey: String
    public var physicalName: String
    public var virtualID: UInt32
    /// The monitor's mode before scaling started.
    public var previousMode: DisplayModeInfo?
    public var verification: VirtualScalingVerification
    public var startedAt: Date
}

public enum VirtualScalingError: Error, Equatable, LocalizedError {
    case unsupported
    case alreadyActive
    case noPlan(ScalingTarget)
    case creationFailed
    case modeUnavailable
    case coreGraphics(operation: String, code: Int32)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "This version of macOS does not offer the virtual display API ScaleKit needs."
        case .alreadyActive:
            "Virtual scaling is already active. Turn it off first."
        case .noPlan(let target):
            "\(target) cannot be produced with a virtual display on this monitor."
        case .creationFailed:
            "macOS did not create the virtual display."
        case .modeUnavailable:
            "The virtual display did not offer the requested HiDPI mode in time."
        case .coreGraphics(let operation, let code):
            "\(operation) failed with CoreGraphics error \(code)."
        case .verificationFailed(let detail):
            "macOS did not confirm the scaled desktop: \(detail)"
        }
    }
}

/// HiDPI scaling at any size through a virtual display and mirroring.
///
/// **Private API.** The virtual display comes from `SKVirtualDisplay`
/// (CoreGraphics' private CGVirtualDisplay). Everything else uses public
/// CoreGraphics calls, and every configuration is applied with `.forAppOnly`,
/// so macOS removes the virtual display and restores the monitor whenever
/// this process exits, including after a crash.
@MainActor
public final class VirtualDisplayScaler {
    public private(set) var session: VirtualScalingSession?
    /// Called when macOS removes the virtual display on its own.
    public var onUnexpectedTermination: (@MainActor (VirtualScalingSession) -> Void)?

    /// Changes the virtual display's identity. WindowServer saves display
    /// sets per identity (mirror master, refresh rate, VRR) and re-applies
    /// them whenever the display appears; bumping this discards a bad set,
    /// for example one saved by System Settings while it reversed the mirror.
    public var identityGeneration: UInt32 = 1

    /// Keep the physical monitor on a fixed-refresh mode that matches the
    /// virtual desktop's size while it mirrors.
    public var pinsPhysicalMode = true

    /// Give the virtual display the monitor's color profile, so frames that
    /// reach the panel without color conversion look the same as converted ones.
    public var matchesPhysicalColorProfile = true
    public var colorProfilesDirectory = AppPaths.standard().colorProfilesDirectory

    private var virtualDisplay: SKVirtualDisplay?
    /// ColorSync device whose custom profile ScaleKit set, cleared on teardown.
    private var colorProfileDevice: CFUUID?
    /// The monitor profile last given to the virtual display.
    private var matchedProfile: Data?
    /// Origins of the other displays before scaling, restored on teardown.
    private var savedOrigins: [DisplayArrangement.Placement] = []
    /// Where the neighbours belong while scaling is on.
    private var scaledPlacements: [DisplayArrangement.Placement] = []
    private var physicalOrigin: DisplayBounds?
    private var repairTimes: [Date] = []
    /// What happened during the current activation, reported on failure.
    private var trace: [String] = []
    private let hardware: DisplayHardware

    public init(hardware: DisplayHardware) {
        self.hardware = hardware
    }

    public static var isSupported: Bool { SKVirtualDisplay.isSupported }

    /// Density reported for the virtual display's backing store. At this
    /// density macOS makes the HiDPI mode the default (seen on macOS 27).
    static let declaredPixelsPerInch = 218.0
    static let nativeFlag: UInt32 = 0x0200_0000

    /// True for displays ScaleKit created.
    public static func isScaleKitVirtualDisplay(vendorID: UInt32) -> Bool {
        vendorID == SKVirtualDisplayVendorID
    }

    public var isActive: Bool { session != nil }

    /// A serial that is stable for one monitor, size and generation.
    static func serialNumber(displayKey: String, percent: Int, generation: UInt32) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in displayKey.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash ^ UInt32(percent) ^ (generation << 20)
    }

    /// Creates the virtual display, mirrors `display` to it and verifies the result.
    /// On any failure everything is undone before the error is thrown.
    public func activate(on display: DisplayInfo, plan: VirtualScalingPlan) async throws -> VirtualScalingSession {
        guard Self.isSupported else { throw VirtualScalingError.unsupported }
        guard session == nil, virtualDisplay == nil else { throw VirtualScalingError.alreadyActive }
        let started = Date()
        let previous = hardware.currentMode(for: display.id)
        let millimeters = CGSize(
            width: Double(plan.pixels.width) / Self.declaredPixelsPerInch * 25.4,
            height: Double(plan.pixels.height) / Self.declaredPixelsPerInch * 25.4)

        // Read the arrangement before the virtual display appears: adding a
        // display can already make macOS move its neighbours.
        let physicalBounds = Self.bounds(of: display.id)
        let others = Self.otherDisplays(excluding: [display.id])
        savedOrigins = others.map {
            DisplayArrangement.Placement(displayID: $0.id, x: Int($0.bounds.x.rounded()), y: Int($0.bounds.y.rounded()))
        }
        scaledPlacements = DisplayArrangement.placements(resized: physicalBounds, newSize: plan.points, others: others)
        physicalOrigin = physicalBounds

        Log.virtual.notice("Creating virtual display \(plan.summary, privacy: .public) for \(display.id)")
        guard let virtual = SKVirtualDisplay(
            name: "ScaleKit \(plan.target) (\(display.displayName))",
            pointWidth: UInt32(plan.points.width),
            pointHeight: UInt32(plan.points.height),
            refreshRate: plan.refreshRate,
            sizeInMillimeters: millimeters,
            serialNumber: Self.serialNumber(
                displayKey: display.key, percent: plan.target.percent, generation: identityGeneration)),
            virtual.displayID != kCGNullDirectDisplay
        else {
            savedOrigins = []
            scaledPlacements = []
            throw VirtualScalingError.creationFailed
        }
        virtualDisplay = virtual
        let virtualID = virtual.displayID

        trace = ["virtual display \(virtualID) created"]
        do {
            // Wait until macOS has finished bringing the display up (its mode
            // list is readable): a mirror requested earlier can be ignored.
            var hiDPI: CGDisplayMode?
            for _ in 0..<40 {
                hiDPI = hiDPIMode(on: virtualID, plan: plan)
                if hiDPI != nil && CGDisplayIsOnline(virtualID) != 0 { break }
                try? await Task.sleep(for: .milliseconds(75))
            }
            trace.append(hiDPI == nil ? "HiDPI mode not listed after 3 s" : "HiDPI mode listed after \(Self.elapsed(since: started))")
            try? await Task.sleep(for: .milliseconds(250))

            var mirrored = false
            for attempt in 1...3 where !mirrored {
                try configure(
                    virtualID: virtualID, physicalID: display.id, mode: hiDPI ?? hiDPIMode(on: virtualID, plan: plan),
                    origin: physicalBounds, placements: scaledPlacements)
                mirrored = await waitForMirror(physicalID: display.id, virtualID: virtualID, seconds: 1.5)
                trace.append("mirror attempt \(attempt): \(mirrored ? "active" : "not active")")
            }
            guard mirrored else {
                throw VirtualScalingError.verificationFailed("macOS did not start mirroring. Steps: \(trace.joined(separator: "; ")).")
            }
            try await ensureHiDPIMode(on: virtualID, plan: plan)
            if pinsPhysicalMode {
                await pinPhysicalMode(physicalID: display.id, virtualID: virtualID, plan: plan, native: display.nativeResolution.value)
            }
            let verification = await verify(virtualID: virtualID, physicalID: display.id, plan: plan, since: started)
            guard verification.mirrorActive, verification.virtualMode?.pixels == plan.pixels else {
                throw VirtualScalingError.verificationFailed(
                    verification.notes.joined(separator: " ") + " Steps: \(trace.joined(separator: "; ")).")
            }
            matchColorProfile(physicalID: display.id, virtualID: virtualID, displayKey: display.key)
            let newSession = VirtualScalingSession(
                id: UUID(), plan: plan, physicalID: display.id, physicalKey: display.key,
                physicalName: display.displayName, virtualID: virtualID, previousMode: previous,
                verification: verification, startedAt: started)
            virtual.terminationHandler = { [weak self] in
                MainActor.assumeIsolated { self?.virtualDisplayTerminated() }
            }
            session = newSession
            repairTimes = []
            scheduleColorProfileChecks(for: newSession)
            Log.virtual.notice("Virtual scaling active: \(plan.summary, privacy: .public)")
            return newSession
        } catch {
            Log.virtual.error("Virtual scaling failed: \(error.localizedDescription, privacy: .public)")
            await tearDown(physicalID: display.id, previous: previous)
            throw error
        }
    }

    /// Removes the virtual display, then restores the monitor's mode and the
    /// arrangement. Returns the monitor's mode afterwards.
    @discardableResult
    public func deactivate() async -> DisplayModeInfo? {
        guard let session else {
            await tearDown(physicalID: nil, previous: nil)
            return nil
        }
        self.session = nil
        Log.virtual.notice("Turning off virtual scaling for \(session.physicalID)")
        return await tearDown(physicalID: session.physicalID, previous: session.previousMode)
    }

    /// How the mirror set looks now, for detecting changes made elsewhere.
    public func mirrorState() -> MirrorState {
        guard let session else { return .inactive }
        if CGDisplayIsOnline(session.physicalID) == 0 { return .monitorOffline }
        if CGDisplayMirrorsDisplay(session.physicalID) == session.virtualID { return .scaling }
        if CGDisplayMirrorsDisplay(session.virtualID) == session.physicalID { return .reversed }
        return .notMirrored
    }

    public enum MirrorState: Sendable, Equatable {
        case inactive, scaling, reversed, notMirrored, monitorOffline
    }

    /// After wake or a reconfiguration, macOS can drop the mirror, re-apply a
    /// saved refresh/VRR setting or move the neighbours. Put everything back.
    /// Limited to three repairs a minute so it can never loop.
    @discardableResult
    public func repairIfNeeded() async -> MirrorState {
        guard let session else { return .inactive }
        let state = mirrorState()
        guard state == .scaling || state == .notMirrored else { return state }
        if state == .scaling {
            matchColorProfile(physicalID: session.physicalID, virtualID: session.virtualID, displayKey: session.physicalKey)
        }
        let now = Date()
        repairTimes = repairTimes.filter { now.timeIntervalSince($0) < 60 }
        let mirrorLost = state == .notMirrored
        let pinNeeded = pinsPhysicalMode && !physicalModeIsAcceptable(session.physicalID, plan: session.plan)
        let moved = scaledPlacements.contains { placement in
            CGDisplayIsOnline(placement.displayID) != 0
                && (Int(CGDisplayBounds(placement.displayID).origin.x.rounded()) != placement.x
                    || Int(CGDisplayBounds(placement.displayID).origin.y.rounded()) != placement.y)
        }
        guard mirrorLost || pinNeeded || moved else { return state }
        guard repairTimes.count < 3 else {
            Log.virtual.notice("Repair limit reached; not touching the configuration again for now")
            return state
        }
        repairTimes.append(now)
        Log.virtual.notice("Repairing virtual scaling (mirror lost: \(mirrorLost), pin: \(pinNeeded), moved: \(moved))")
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            if mirrorLost {
                CGConfigureDisplayMirrorOfDisplay(config, session.physicalID, session.virtualID)
            }
            for placement in scaledPlacements where CGDisplayIsOnline(placement.displayID) != 0 {
                CGConfigureDisplayOrigin(config, placement.displayID, Int32(placement.x), Int32(placement.y))
            }
            if CGCompleteDisplayConfiguration(config, .forAppOnly) != .success {
                CGCancelDisplayConfiguration(config)
            }
        }
        if pinsPhysicalMode {
            await pinPhysicalMode(
                physicalID: session.physicalID, virtualID: session.virtualID, plan: session.plan, native: session.plan.native)
        }
        try? await Task.sleep(for: .milliseconds(300))
        return mirrorState()
    }

    // MARK: - Steps

    static func elapsed(since start: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(start))
    }

    private func waitForMirror(physicalID: CGDirectDisplayID, virtualID: CGDirectDisplayID, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if CGDisplayMirrorsDisplay(physicalID) == virtualID { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return CGDisplayMirrorsDisplay(physicalID) == virtualID
    }

    private func hiDPIMode(on virtualID: CGDirectDisplayID, plan: VirtualScalingPlan) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(virtualID, options) as? [CGDisplayMode] ?? []
        return modes.first {
            $0.width == plan.points.width && $0.height == plan.points.height
                && $0.pixelWidth == plan.pixels.width && $0.pixelHeight == plan.pixels.height
        }
    }

    /// The HiDPI mode is normally the default. If macOS chose the 1× mode,
    /// switch once the mode list is readable.
    private func ensureHiDPIMode(on virtualID: CGDirectDisplayID, plan: VirtualScalingPlan) async throws {
        for _ in 0..<30 {
            if let current = CGDisplayCopyDisplayMode(virtualID),
               current.pixelWidth == plan.pixels.width, current.width == plan.points.width {
                return
            }
            if let mode = hiDPIMode(on: virtualID, plan: plan) {
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
                CGConfigureDisplayWithDisplayMode(config, virtualID, mode, nil)
                let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
                guard result == .success else {
                    throw VirtualScalingError.coreGraphics(operation: "CGConfigureDisplayWithDisplayMode", code: result.rawValue)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func configure(
        virtualID: CGDirectDisplayID, physicalID: CGDirectDisplayID, mode: CGDisplayMode?, origin: DisplayBounds,
        placements: [DisplayArrangement.Placement]
    ) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            throw VirtualScalingError.coreGraphics(operation: "CGBeginDisplayConfiguration", code: begin.rawValue)
        }
        if let mode {
            CGConfigureDisplayWithDisplayMode(config, virtualID, mode, nil)
        }
        CGConfigureDisplayOrigin(config, virtualID, Int32(origin.x), Int32(origin.y))
        // Keep neighbours against the smaller desktop's edges in the same
        // transaction, so macOS does not rearrange displays (and the Dock) itself.
        for placement in placements {
            CGConfigureDisplayOrigin(config, placement.displayID, Int32(placement.x), Int32(placement.y))
        }
        let mirror = CGConfigureDisplayMirrorOfDisplay(config, physicalID, virtualID)
        guard mirror == .success else {
            CGCancelDisplayConfiguration(config)
            throw VirtualScalingError.coreGraphics(operation: "CGConfigureDisplayMirrorOfDisplay", code: mirror.rawValue)
        }
        let complete = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard complete == .success else {
            throw VirtualScalingError.coreGraphics(operation: "CGCompleteDisplayConfiguration", code: complete.rawValue)
        }
    }

    /// The best mode for the mirroring monitor: the virtual desktop's own
    /// point size at the planned fixed refresh rate, so both members of the
    /// mirror set report the same bounds. Falls back to the panel's native
    /// mode at that rate.
    private func pinTarget(_ physicalID: CGDirectDisplayID, plan: VirtualScalingPlan, native: PixelSize?) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(physicalID, options) as? [CGDisplayMode] ?? [])
            .filter { abs($0.refreshRate - plan.refreshRate) < 0.5 }
        let sameSize = modes.filter { $0.width == plan.points.width && $0.height == plan.points.height }
        if let best = sameSize.max(by: { $0.pixelWidth < $1.pixelWidth }) { return best }
        guard let native else { return nil }
        return modes.first {
            $0.pixelWidth == native.width && $0.width == native.width && ($0.ioFlags & Self.nativeFlag) != 0
        }
    }

    private func physicalModeIsAcceptable(_ physicalID: CGDirectDisplayID, plan: VirtualScalingPlan) -> Bool {
        guard let current = CGDisplayCopyDisplayMode(physicalID) else { return true }
        guard abs(current.refreshRate - plan.refreshRate) < 0.5 else { return false }
        if current.width == plan.points.width && current.height == plan.points.height { return true }
        // Native fallback is acceptable only when no same-size mode exists.
        return pinTarget(physicalID, plan: plan, native: plan.native).map {
            $0.width == current.width && $0.pixelWidth == current.pixelWidth
        } ?? true
    }

    /// Best effort: put the mirroring monitor on a fixed-refresh mode. If
    /// macOS drops mirroring as a result, mirroring is re-established.
    private func pinPhysicalMode(
        physicalID: CGDirectDisplayID, virtualID: CGDirectDisplayID, plan: VirtualScalingPlan, native: PixelSize?
    ) async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !physicalModeIsAcceptable(physicalID, plan: plan) else { return }
        guard let target = pinTarget(physicalID, plan: plan, native: native) else {
            Log.virtual.notice("No fixed \(plan.refreshRate) Hz mode to pin the mirroring monitor to")
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayWithDisplayMode(config, physicalID, target, nil)
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        Log.virtual.notice("Pinned mirroring monitor to \(target.width)×\(target.height) @ \(target.refreshRate) Hz: CGError \(result.rawValue)")
        trace.append("pin \(target.width)×\(target.height)@\(Int(target.refreshRate.rounded())) (CGError \(result.rawValue))")
        if await waitForMirror(physicalID: physicalID, virtualID: virtualID, seconds: 0.8) { return }
        // The pin broke the mirror set: give up the pin and mirror again.
        trace.append("pin dropped the mirror; re-mirroring without it")
        for _ in 0..<2 {
            var again: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&again) == .success, let again else { return }
            CGConfigureDisplayMirrorOfDisplay(again, physicalID, virtualID)
            if CGCompleteDisplayConfiguration(again, .forAppOnly) != .success {
                CGCancelDisplayConfiguration(again)
            }
            if await waitForMirror(physicalID: physicalID, virtualID: virtualID, seconds: 1.2) { return }
        }
    }

    private func verify(
        virtualID: CGDirectDisplayID, physicalID: CGDirectDisplayID, plan: VirtualScalingPlan, since start: Date
    ) async -> VirtualScalingVerification {
        var result = snapshot(virtualID: virtualID, physicalID: physicalID, plan: plan, since: start)
        for _ in 0..<40 where !result.isVerified(for: plan) {
            try? await Task.sleep(for: .milliseconds(100))
            result = snapshot(virtualID: virtualID, physicalID: physicalID, plan: plan, since: start)
        }
        return result
    }

    private func snapshot(
        virtualID: CGDirectDisplayID, physicalID: CGDirectDisplayID, plan: VirtualScalingPlan, since start: Date
    ) -> VirtualScalingVerification {
        let mirrored = CGDisplayMirrorsDisplay(physicalID) == virtualID
        let virtualMode = hardware.currentMode(for: virtualID)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == virtualID
        }
        let size = screen.map { PixelSize(width: Int($0.frame.width.rounded()), height: Int($0.frame.height.rounded())) }
        let physicalMode = hardware.currentMode(for: physicalID)
        var notes: [String] = []
        if !mirrored { notes.append("The monitor is not mirroring the virtual display.") }
        if let virtualMode, virtualMode.pixels != plan.pixels || virtualMode.logical != plan.points {
            notes.append("The virtual display is in \(virtualMode.summary), not \(plan.summary).")
        } else if virtualMode == nil {
            notes.append("CoreGraphics reports no mode for the virtual display.")
        }
        if let scale = screen?.backingScaleFactor, abs(scale - 2) > 0.01 {
            notes.append(String(format: "AppKit reports a %.1f× scale factor, not 2×.", scale))
        }
        if let physicalMode, physicalMode.refreshRate > 0, abs(physicalMode.refreshRate - plan.refreshRate) > 0.5 {
            notes.append("The monitor reports \(physicalMode.refreshLabel) while mirrored, not \(RefreshRate.label(plan.refreshRate)).")
        }
        if CGDisplayBounds(physicalID).size != CGDisplayBounds(virtualID).size {
            notes.append("The monitor's reported bounds differ from the scaled desktop's.")
        }
        return VirtualScalingVerification(
            mirrorActive: mirrored, virtualMode: virtualMode, screenScale: screen.map { Double($0.backingScaleFactor) },
            screenSize: size, physicalMode: physicalMode, notes: notes,
            elapsedSeconds: Date().timeIntervalSince(start))
    }

    /// Removes the virtual display first (its mirror set dissolves with it,
    /// so it never stands alone as an extended display), then restores the
    /// monitor's previous mode and the neighbours' origins in one transaction.
    @discardableResult
    private func tearDown(physicalID: CGDirectDisplayID?, previous: DisplayModeInfo?) async -> DisplayModeInfo? {
        let virtualID = virtualDisplay?.displayID ?? kCGNullDirectDisplay
        clearColorProfile()
        virtualDisplay?.terminationHandler = nil
        virtualDisplay?.invalidate()
        virtualDisplay = nil
        if virtualID != kCGNullDirectDisplay {
            for _ in 0..<40 where CGDisplayIsOnline(virtualID) != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        await restoreArrangement(physicalID: physicalID, previous: previous)
        guard let physicalID else { return nil }

        var current = hardware.currentMode(for: physicalID)
        for _ in 0..<20 where previous != nil && current?.signature != previous?.signature {
            try? await Task.sleep(for: .milliseconds(100))
            current = hardware.currentMode(for: physicalID)
        }
        if let previous, current?.signature != previous.signature {
            Log.virtual.notice("Monitor not back to \(previous.summary, privacy: .public); restoring permanent configuration")
            CGRestorePermanentDisplayConfiguration()
            try? await Task.sleep(for: .milliseconds(1500))
            current = hardware.currentMode(for: physicalID)
        }
        return current
    }

    private func restoreArrangement(physicalID: CGDirectDisplayID?, previous: DisplayModeInfo?) async {
        let origins = savedOrigins.filter { CGDisplayIsOnline($0.displayID) != 0 }
        let physicalBounds = physicalOrigin
        savedOrigins = []
        scaledPlacements = []
        physicalOrigin = nil
        var previousMode: CGDisplayMode?
        if let physicalID, let previous, CGDisplayIsOnline(physicalID) != 0,
           hardware.currentMode(for: physicalID)?.signature != previous.signature {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            previousMode = (CGDisplayCopyAllDisplayModes(physicalID, options) as? [CGDisplayMode])?.first {
                $0.ioDisplayModeID == previous.modeID
            }
        }
        guard !origins.isEmpty || previousMode != nil else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        if let physicalID, let previousMode {
            CGConfigureDisplayWithDisplayMode(config, physicalID, previousMode, nil)
        }
        if let physicalID, let physicalBounds, CGDisplayIsOnline(physicalID) != 0 {
            CGConfigureDisplayOrigin(config, physicalID, Int32(physicalBounds.x), Int32(physicalBounds.y))
        }
        for placement in origins {
            CGConfigureDisplayOrigin(config, placement.displayID, Int32(placement.x), Int32(placement.y))
        }
        if CGCompleteDisplayConfiguration(config, .forAppOnly) != .success {
            CGCancelDisplayConfiguration(config)
        }
    }

    static func bounds(of id: CGDirectDisplayID) -> DisplayBounds {
        let b = CGDisplayBounds(id)
        return DisplayBounds(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height)
    }

    /// Online, active displays other than `excluded`, with their bounds.
    static func otherDisplays(excluding excluded: Set<CGDirectDisplayID>) -> [(id: UInt32, bounds: DisplayBounds)] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard !excluded.contains(id), CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  !isScaleKitVirtualDisplay(vendorID: CGDisplayVendorNumber(id))
            else { return nil }
            return (id, bounds(of: id))
        }
    }

    /// macOS swaps the monitor's own profile for one regenerated from its
    /// EDID once it joins the mirror set (a 2.2 curve becomes 1.96 on an
    /// ASUS VG34WQML5A), so the profile is read only after mirroring, and
    /// again whenever it may have changed. Unchanged profiles are not re-sent.
    private func matchColorProfile(physicalID: CGDirectDisplayID, virtualID: CGDirectDisplayID, displayKey: String) {
        guard matchesPhysicalColorProfile, let icc = VirtualColorProfile.iccData(of: physicalID),
              matchedProfile.map({ !VirtualColorProfile.isSame($0, icc) }) ?? true
        else { return }
        let device = VirtualColorProfile.assign(
            icc, to: virtualID, fileName: Self.profileFileName(displayKey: displayKey), directory: colorProfilesDirectory)
        colorProfileDevice = device ?? colorProfileDevice
        matchedProfile = device == nil ? nil : icc
        trace.append(device == nil ? "color profile not matched" : "color profile matched to the monitor (\(icc.count) B)")
        Log.virtual.notice("Virtual display color profile \(device == nil ? "not matched" : "matched to the monitor", privacy: .public)")
    }

    /// The monitor's mirror profile is written a moment after mirroring starts.
    private func scheduleColorProfileChecks(for started: VirtualScalingSession) {
        guard matchesPhysicalColorProfile else { return }
        Task { [weak self] in
            for delay in [1, 3] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.session?.id == started.id else { return }
                self.matchColorProfile(
                    physicalID: started.physicalID, virtualID: started.virtualID, displayKey: started.physicalKey)
            }
        }
    }

    private func clearColorProfile() {
        matchedProfile = nil
        guard let device = colorProfileDevice else { return }
        colorProfileDevice = nil
        VirtualColorProfile.clear(device: device)
    }

    /// One profile file per monitor, overwritten on each activation.
    static func profileFileName(displayKey: String) -> String {
        let safe = displayKey.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_"
        }
        return "monitor-" + String(safe)
    }

    private func virtualDisplayTerminated() {
        clearColorProfile()
        virtualDisplay = nil
        guard let ended = session else { return }
        session = nil
        Log.virtual.notice("macOS removed the virtual display")
        Task { [weak self] in
            await self?.restoreArrangement(physicalID: ended.physicalID, previous: ended.previousMode)
            self?.onUnexpectedTermination?(ended)
        }
    }
}

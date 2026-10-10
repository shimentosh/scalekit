// scalekit-diag — ScaleKit's command-line display diagnostic tool.
//
// Read-only commands (displays, modes, profiles, report, watch) never change
// the display configuration. `trial` applies a mode through the same
// RecoveryService the app uses, so it doubles as a hardware validation harness.

import AppKit
import ScaleKitCore
import ScaleKitVirtual

let usage = """
    scalekit-diag — inspect displays and validate ScaleKit's scaling engine

    USAGE
      scalekit-diag displays
      scalekit-diag modes      [--display ID] [--all]
      scalekit-diag profiles   [--display ID] [--refresh HZ] [--desired PERCENT]
      scalekit-diag report     [--out DIR] [--no-profiler] [--refresh HZ] [--desired PERCENT]
      scalekit-diag watch      [--seconds N]
      scalekit-diag trial      --display ID --mode MODE_ID [--seconds N] [--timeout N]
                               [--keep] [--accept-refresh-reduction]
                               [--simulate-hang] [--exit-without-revert]
      scalekit-diag virtual    --check [--display ID] [--refresh HZ]
      scalekit-diag virtual    --percent P [--display ID] [--seconds N] [--timeout N] [--refresh HZ]
                               [--simulate-hang] [--exit-without-revert] [--no-pin] [--no-color-match]
      scalekit-diag recover
      scalekit-diag journal

    NOTES
      Read-only commands never change your displays.
      `trial` applies a mode for this process only (kCGConfigureForAppOnly), verifies it,
      waits --seconds (default 5), then reverts — or saves it permanently with --keep.
      `virtual` (EXPERIMENTAL, private API) creates a HiDPI virtual display, mirrors the
      monitor to it for --seconds (default 10), then turns it off. --check changes nothing.
      Files are kept in ~/Library/Application Support/ScaleKit (override: SCALEKIT_SUPPORT_DIR).
    """

struct Arguments {
    var command: String
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        command = raw.first ?? "help"
        var index = 1
        while index < raw.count {
            let item = raw[index]
            guard item.hasPrefix("--") else { index += 1; continue }
            let key = String(item.dropFirst(2))
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                options[key] = raw[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
    }

    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }
    func double(_ key: String) -> Double? { options[key].flatMap(Double.init) }
}

func out(_ text: String = "") {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

/// Deliberately freezes the main thread to simulate an unresponsive app.
func blockMainThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

func fail(_ text: String) -> Int32 {
    FileHandle.standardError.write(Data(("error: " + text + "\n").utf8))
    return 1
}

func tag(_ provenance: Provenance) -> String {
    switch provenance {
    case .measured: "[M]"
    case .inferred: "[I]"
    case .unavailable: "[U]"
    }
}

func show<T>(_ fact: Fact<T>, _ format: (T) -> String) -> String {
    "\(fact.value.map(format) ?? "—") \(tag(fact.provenance))"
}

@MainActor
struct CLI {
    let args: Arguments
    let services = ScaleKitServices.live()

    var preferredRefresh: Double { args.double("refresh") ?? 120 }
    var desired: ScalingTarget { ScalingTarget(percent: args.int("desired") ?? 150) }

    func run() async -> Int32 {
        switch args.command {
        case "displays": return displays()
        case "modes": return modes()
        case "profiles": return profiles()
        case "report": return await report()
        case "watch": return await watch()
        case "trial": return await trial()
        case "recover": return await recover()
        case "virtual": return await virtual()
        case "journal": return journal()
        case "help", "--help", "-h": out(usage); return 0
        default: out(usage); return 2
        }
    }

    func target(_ displays: [DisplayInfo]) -> DisplayInfo? {
        if let id = args.int("display") { return displays.first { $0.id == UInt32(id) } }
        if let match = DisplayDiscoveryService.match(.asusVG34WQML5A, in: displays) {
            return displays.first { $0.id == match.displayID }
        }
        return displays.first { $0.isMain } ?? displays.first
    }

    func displays() -> Int32 {
        let displays = services.discovery.discover()
        out("Legend: [M] measured · [I] inferred · [U] unavailable")
        out(EnvironmentInfo.current().summary)
        let match = DisplayDiscoveryService.match(.asusVG34WQML5A, in: displays)
        for display in displays {
            let status = services.hiDPI.status(for: display.id)
            out()
            out("Display \(display.id) · \(display.displayName) (\(display.isMain ? "main" : "secondary"), \(display.isBuiltin ? "built-in" : "external"))")
            out("  Manufacturer   \(show(display.manufacturer) { $0 })   \(display.identity.hexDescription)")
            out("  Connection     \(show(display.connection) { $0 })")
            out("  Physical size  \(show(display.physicalSize) { $0.description })   density \(show(display.pixelDensity) { String(format: "%.0f PPI", $0) })")
            out("  Native         \(show(display.nativeResolution) { $0.description })")
            out("  Looks like     \(show(display.logicalResolution) { "\($0) pt" })")
            out("  Backing store  \(show(display.framebufferResolution) { "\($0) px" })")
            out("  Output signal  \(show(display.physicalOutput) { "\($0) px" })")
            out("  Scale factor   \(show(display.backingScaleFactor) { "\($0)×" })   HiDPI: \(status.label) (confidence \(status.confidence.label))")
            out("  Refresh        \(show(display.refreshRate) { RefreshRate.label($0) })   max FPS \(show(display.maximumFramesPerSecond) { "\($0)" })")
            if let mode = display.currentMode {
                out("  Active mode    ID \(mode.modeID) · flags \(mode.flags.hexDescription) [\(mode.flags.names.joined(separator: ","))]")
            }
            if match?.displayID == display.id, let match {
                out("  Target match   \(match.monitorName) — confidence \(match.confidence.label): \(match.reasons.joined(separator: "; "))")
            }
        }
        return 0
    }

    func modes() -> Int32 {
        let displays = services.discovery.discover()
        guard let display = target(displays) else { return fail("No display found.") }
        let all = services.modes.allModes(for: display.id)
        let list = args.flags.contains("all") ? all : DisplayModeService.desktopModes(from: all)
        let native = display.nativeResolution.value
        out("Display \(display.id) · \(display.displayName) · native \(native?.description ?? "unknown")")
        out("\(list.count) modes shown (\(all.count) reported including HiDPI duplicates)")
        out("   ID  Looks like     Backing        Scale  Refresh   Native  GUI  Rendering")
        for mode in list {
            let path = HiDPIDetection.renderingPath(for: mode, native: native)
            let current = display.currentMode?.signature == mode.signature ? "  ← active" : ""
            out(String(
                format: "%5d  %-13@  %-13@  %4.1f×  %-8@  %-6@  %-3@  %@%@",
                mode.modeID, "\(mode.logical)" as NSString, "\(mode.pixels)" as NSString, mode.scaleFactor,
                mode.refreshLabel as NSString, (mode.hasNativeFlag ? "yes" : "no") as NSString,
                (mode.isUsableForDesktopGUI ? "yes" : "no") as NSString, path.label as NSString, current as NSString))
        }
        return 0
    }

    func profiles() -> Int32 {
        let displays = services.discovery.discover()
        guard let display = target(displays) else { return fail("No display found.") }
        let evaluations = services.profiles.evaluations(for: display, preferredRefresh: preferredRefresh)
        out("Display \(display.id) · \(display.displayName) · preferred refresh \(RefreshRate.label(preferredRefresh))")
        for evaluation in evaluations {
            out()
            out("\(evaluation.target) — \(evaluation.status.label.uppercased())\(evaluation.isCurrent ? " (current)" : "")")
            out("  \(evaluation.explanation)")
            if let selection = evaluation.selection {
                out("  Mode \(selection.mode.modeID): \(selection.mode.summary) · output \(selection.physicalOutput.value?.description ?? "unknown") · \(selection.renderingPath.label)")
                for note in selection.tradeOffs { out("  • \(note)") }
            }
            for (index, alternative) in evaluation.alternatives.enumerated() {
                out("  Alternative \(index + 1): \(alternative.uiPercent)% · \(alternative.mode.summary) (mode \(alternative.mode.modeID), \(alternative.status.label), score \(Int(alternative.score.total.rounded())))")
                for note in alternative.tradeOffs { out("     • \(note)") }
            }
        }
        if let recommendation = services.profiles.recommendation(
            for: display, desired: desired, preferredRefresh: preferredRefresh, evaluations: evaluations) {
            out()
            out("Recommendation for \(desired): \(recommendation.headline)")
            for reason in recommendation.reasons { out("  • \(reason)") }
        }
        return 0
    }

    func report() async -> Int32 {
        let report = await services.diagnostics.makeReport(
            preferredRefresh: preferredRefresh, desired: desired,
            includeSystemProfiler: !args.flags.contains("no-profiler"))
        if let directory = args.options["out"] {
            do {
                let urls = try DiagnosticsService.write(report, to: URL(fileURLWithPath: directory, isDirectory: true))
                out("Wrote \(urls.markdown.path)")
                out("Wrote \(urls.json.path)")
            } catch {
                return fail("Could not write report: \(error.localizedDescription)")
            }
        } else {
            out(DiagnosticMarkdown.render(report))
        }
        return 0
    }

    func watch() async -> Int32 {
        let seconds = args.int("seconds") ?? 30
        services.events.addHandler { event in
            let stamp = ISO8601DateFormatter().string(from: Date())
            out("\(stamp)  \(event.description)")
        }
        services.events.start()
        out("Watching display events for \(seconds) s (connect, disconnect, mode, sleep, wake)…")
        try? await Task.sleep(for: .seconds(seconds))
        services.events.stop()
        out("Stopped. \(services.events.recentEvents.count) event(s) observed.")
        return 0
    }

    func trial() async -> Int32 {
        guard let displayID = args.int("display"), let modeID = args.int("mode") else {
            return fail("trial needs --display ID and --mode MODE_ID (see `modes`).")
        }
        let seconds = args.double("seconds") ?? 5
        let recovery = services.recovery
        recovery.confirmationTimeout = args.double("timeout") ?? max(15, seconds + 10)
        services.configuration.useSecondaryProbe = true

        guard let display = services.discovery.display(withID: UInt32(displayID)) else {
            return fail("Display \(displayID) is not connected.")
        }
        guard let mode = services.modes.mode(withID: Int32(modeID), for: display.id) else {
            return fail("Display \(displayID) does not offer mode \(modeID).")
        }

        let plan = services.configuration.plan(for: display, target: mode)
        out("Display \(display.id) · \(display.displayName)")
        for row in plan.rows {
            out(String(format: "  %-16@ %-30@ → %@%@", row.label as NSString, row.before as NSString, row.after as NSString, row.changed ? "" : "  (unchanged)"))
        }
        for error in plan.validation.errors { out("  ✗ \(error)") }
        for warning in plan.validation.warnings { out("  ! \(warning)") }
        guard plan.validation.isValid else { return fail("Validation failed; nothing was changed.") }

        let targetID = display.id
        services.events.addHandler { [services] event in
            out("  event: \(event.description)")
            guard let session = services.recovery.state.session else { return }
            switch event {
            case .systemWillSleep:
                Task { await services.recovery.handle(.systemWillSleep) }
            case .reconfigured(let id, let changes) where id == targetID && changes.contains(.removed):
                Task { await services.recovery.handle(.targetDisplayRemoved) }
            case .reconfigured(let id, let changes) where id == targetID && changes.contains(.setMode):
                if services.modes.currentMode(for: id)?.signature != session.target.signature {
                    Task { await services.recovery.handle(.targetDisplayChangedExternally) }
                }
            default:
                break
            }
        }
        services.events.start()

        out("Applying for this process only (kCGConfigureForAppOnly)…")
        let state = await recovery.beginTrial(
            on: display, to: mode, acceptRefreshReduction: args.flags.contains("accept-refresh-reduction"))
        guard case .awaitingConfirmation(let session) = state else {
            if case .finished(let outcome) = state { out("Outcome: \(outcome)") }
            return fail("Trial did not start.")
        }
        let verification = session.verification
        out("Verification: \(verification.level.rawValue.uppercased()) after \(String(format: "%.2f", verification.elapsedSeconds)) s")
        for note in verification.notes { out("  • \(note)") }
        out("  NSScreen.backingScaleFactor: \(show(verification.screenScale) { "\($0)" })")
        out("  NSScreen.frame size:         \(show(verification.screenSize) { "\($0)" })")
        out("  system_profiler:             \(show(verification.secondary) { $0 })")
        out("  Journal: \(recovery.currentJournal()?.state.rawValue ?? "missing") · deadline in \(Int(session.deadline.timeIntervalSinceNow)) s · pid \(getpid())")

        if args.flags.contains("simulate-hang") {
            out("Simulating a hang: blocking the main thread. The watchdog should terminate this process after the deadline plus \(Int(recovery.guardGrace)) s.")
            blockMainThread(seconds: 600)
            return 3
        }

        out("Holding for \(seconds) s…")
        try? await Task.sleep(for: .seconds(seconds))

        if args.flags.contains("exit-without-revert") {
            out("Exiting without reverting; macOS should restore the previous mode as this process ends.")
            return 0
        }
        if args.flags.contains("keep") {
            await recovery.keep()
        } else {
            await recovery.revert()
        }
        if case .finished(let outcome) = recovery.state {
            switch outcome {
            case .kept(_, let verification):
                out("KEPT permanently — verification \(verification.level.rawValue).")
            case .reverted(_, let reason, let restored):
                out("REVERTED — \(reason) Restore verification: \(restored?.level.rawValue ?? "previous mode already active").")
            default:
                out("Outcome: \(outcome)")
            }
        }
        let after = services.modes.currentMode(for: display.id)
        out("Active mode now: \(after?.summary ?? "unknown") (ID \(after.map { String($0.modeID) } ?? "?")) · journal \(recovery.currentJournal()?.state.rawValue ?? "missing")")
        services.events.stop()
        return 0
    }

    func recover() async -> Int32 {
        let displays = services.discovery.discover()
        if let report = await services.recovery.recoverAfterLaunch(displays: displays) {
            out("Recovery: \(report.assessment) — \(report.message)")
        } else {
            out("Nothing to recover. Journal state: \(services.recovery.currentJournal()?.state.rawValue ?? "none").")
        }
        return 0
    }

    func journal() -> Int32 {
        guard let journal = services.recovery.currentJournal() else {
            out("No trial journal.")
            return 0
        }
        out("Trial \(journal.trialID) · \(journal.state.rawValue) · pid \(journal.appPID) · \(journal.displayName)")
        out("  previous \(journal.previous.summary) → target \(journal.target.summary)")
        out("  note: \(journal.note ?? "—")")
        return 0
    }
}

extension CLI {
    /// EXPERIMENTAL: HiDPI scaling through a virtual display. Uses the same
    /// VirtualScalingService as the app (journal, watchdog, app-only changes).
    func virtual() async -> Int32 {
        let displays = services.discovery.discover()
            .filter { !VirtualDisplayScaler.isScaleKitVirtualDisplay(vendorID: $0.identity.vendorID) }
        guard let display = target(displays) else { return fail("No display found.") }
        guard let native = display.nativeResolution.value else { return fail("Native resolution unknown.") }
        let refresh = args.double("refresh") ?? display.refreshRate.value ?? 60
        out("Private CGVirtualDisplay API available: \(VirtualScalingService.isSupported ? "yes" : "NO")")
        out("Display \(display.id) · \(display.displayName) · native \(native) · \(RefreshRate.label(refresh))")

        if args.flags.contains("check") {
            for target in ScalingTarget.standard {
                guard let plan = VirtualScalingPlan(target: target, native: native, refreshRate: refresh) else {
                    out("  \(target): not needed (a native mode exists) or not possible")
                    continue
                }
                out(String(format: "  %@: %@ · sampling %.2f× · GPU load %.1f×",
                           target.description as NSString, plan.summary as NSString, plan.sampling, plan.renderLoad))
            }
            return 0
        }

        guard let percent = args.int("percent"),
              let plan = VirtualScalingPlan(target: ScalingTarget(percent: percent), native: native, refreshRate: refresh)
        else { return fail("--percent must be between \(VirtualScalingPlan.supportedPercents.lowerBound) and \(VirtualScalingPlan.supportedPercents.upperBound).") }
        guard VirtualScalingService.isSupported else { return fail("This macOS does not offer CGVirtualDisplay.") }

        let service = VirtualScalingService(
            hardware: services.hardware, paths: services.paths, history: services.history,
            journalURL: services.paths.root.appendingPathComponent("virtual-trial-cli.json"))
        service.confirmationTimeout = TimeInterval(args.int("timeout") ?? 30)
        service.scaler.pinsPhysicalMode = !args.flags.contains("no-pin")
        out("Pin monitor to its native timing while mirrored: \(service.scaler.pinsPhysicalMode ? "yes" : "no (--no-pin)")")
        service.scaler.matchesPhysicalColorProfile = !args.flags.contains("no-color-match")
        out("Give the virtual display the monitor's color profile: \(service.scaler.matchesPhysicalColorProfile ? "yes" : "no (--no-color-match)")")
        service.onOutcome = { outcome in out("Outcome: \(outcome)") }
        let targetID = display.id
        services.events.addHandler { event in
            out("  event: \(event.description)")
            switch event {
            case .systemWillSleep:
                Task { await service.systemWillSleep() }
            case .systemDidWake:
                Task { await service.systemDidWake() }
            case .reconfigured(let id, let changes) where id == targetID && changes.contains(.removed):
                Task { await service.displayRemoved(id) }
            default:
                break
            }
        }
        services.events.start()

        out("Plan: \(plan.summary)")
        for note in plan.tradeOffs { out("  • \(note)") }
        out("Applying for this process only…")
        await service.beginTrial(on: display, plan: plan)
        guard case .awaitingConfirmation(let session, let deadline) = service.state else {
            return fail("Virtual scaling did not start.")
        }
        let v = session.verification
        out("Verification: \(v.isVerified(for: plan) ? "VERIFIED" : "NOT VERIFIED") after \(String(format: "%.2f", v.elapsedSeconds)) s")
        out("  Mirroring active:          \(v.mirrorActive)")
        out("  Virtual display mode:      \(v.virtualMode?.summary ?? "not reported")")
        out("  NSScreen scale / size:     \(v.screenScale.map { "\($0)×" } ?? "?") / \(v.screenSize.map { "\($0) pt" } ?? "?")")
        out("  Monitor mode while mirrored: \(v.physicalMode?.summary ?? "not reported")")
        for note in v.notes { out("  ! \(note)") }
        out("  Countdown deadline in \(Int(deadline.timeIntervalSinceNow)) s · pid \(getpid())")

        if args.flags.contains("simulate-hang") {
            out("Simulating a hang. The watchdog should end this process after the deadline plus grace.")
            blockMainThread(seconds: 600)
            return 3
        }
        let seconds = args.int("seconds") ?? 10
        out("Holding for \(seconds) s…")
        try? await Task.sleep(for: .seconds(seconds))
        if args.flags.contains("exit-without-revert") {
            out("Exiting without turning it off; macOS should remove the virtual display as this process ends.")
            return 0
        }
        await service.turnOff(reason: "Validation run finished", automatic: false, forget: false)
        let after = services.modes.currentMode(for: display.id)
        out("Monitor after turn-off: \(after?.summary ?? "not reported") · mirrored: \(CGDisplayMirrorsDisplay(display.id) != 0)")
        return after?.signature == display.currentMode?.signature ? 0 : 1
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let args: Arguments

    init(args: Arguments) { self.args = args }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = self.args
        Task { @MainActor in
            let code = await CLI(args: args).run()
            exit(code)
        }
    }
}

// A full NSApplication run loop keeps NSScreen up to date after mode changes,
// which the verification step depends on.
let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let delegate = Delegate(args: arguments)
application.delegate = delegate
application.run()

import AppKit
import ScaleKitCore
import ScaleKitVirtual

/// A virtual-scaling change waiting in its review sheet. Nothing has been
/// applied while a request exists.
struct VirtualScalingRequest: Identifiable {
    let id = UUID()
    let displayID: UInt32
    let displayName: String
    let currentMode: DisplayModeInfo?
    let plan: VirtualScalingPlan
    let timeout: Int
}

/// EXPERIMENTAL: HiDPI scaling at in-between sizes through a virtual display.
/// The trial reuses the confirmation panels of ordinary mode changes.
extension AppModel {
    var isVirtualScalingSupported: Bool { VirtualScalingService.isSupported }

    /// The virtual-scaling session for the monitor, if one is running.
    func virtualSession(for display: DisplayInfo?) -> VirtualScalingSession? {
        guard let display, let session = virtualState.session else { return nil }
        return session.physicalKey == display.key ? session : nil
    }

    func isVirtuallyScaled(_ display: DisplayInfo?) -> Bool {
        virtualSession(for: display) != nil
    }

    var isVirtualTrial: Bool {
        if case .awaitingConfirmation = virtualState { return true }
        return false
    }

    /// The plan for the selected size on the selected monitor, offered only
    /// when macOS has no clean mode for it.
    var virtualPlan: VirtualScalingPlan? {
        guard let evaluation = selectedEvaluation else { return nil }
        return virtualPlan(for: evaluation, on: selectedDisplay)
    }

    func virtualPlan(for evaluation: ProfileEvaluation, on display: DisplayInfo?) -> VirtualScalingPlan? {
        guard isVirtualScalingSupported, evaluation.selection == nil,
              let display, let native = display.nativeResolution.value
        else { return nil }
        return VirtualScalingPlan(target: evaluation.target, native: native, refreshRate: virtualRefresh(for: display))
    }

    /// The status shown to the user. A size macOS lacks but a virtual display
    /// can produce is Experimental rather than Unsupported.
    func displayStatus(_ evaluation: ProfileEvaluation, on display: DisplayInfo?) -> SupportStatus {
        if let display, let session = virtualSession(for: display), session.plan.target == evaluation.target {
            return session.verification.isVerified(for: session.plan) ? .verified : .experimental
        }
        guard let plan = virtualPlan(for: evaluation, on: display) else { return evaluation.status }
        return isVirtualPlanVerified(plan, on: display) ? .verified : .experimental
    }

    /// Kept on this Mac before, with CoreGraphics and AppKit confirming the
    /// 2× HiDPI desktop: the same bar as a verified native mode.
    func isVirtualPlanVerified(_ plan: VirtualScalingPlan, on display: DisplayInfo?) -> Bool {
        guard let display else { return false }
        return services.verifications.verifiedSignatures(for: Self.virtualVerificationKey(display.key))
            .contains(plan.modeInfo.signature)
    }

    /// Virtual results are stored apart from the monitor's own modes, which
    /// diagnostics lists as the monitor's verified modes.
    static func virtualVerificationKey(_ displayKey: String) -> String { displayKey + "#virtual" }

    /// True when the size is the one virtual scaling is currently producing.
    func isVirtualCurrent(_ evaluation: ProfileEvaluation, on display: DisplayInfo?) -> Bool {
        virtualSession(for: display)?.plan.target == evaluation.target
    }

    /// "Current" for a size. While a monitor is virtually scaled its own mode
    /// says nothing about the interface size, so only the virtual size counts.
    func isCurrent(_ evaluation: ProfileEvaluation, on display: DisplayInfo?) -> Bool {
        isVirtuallyScaled(display) ? isVirtualCurrent(evaluation, on: display) : evaluation.isCurrent
    }

    var canStartVirtualScaling: Bool {
        // One size at a time: turn the current one off first, so the journal
        // and saved preference always describe a single session.
        guard !isBusy, virtualPlan != nil, virtualState.session == nil else { return false }
        return services.recovery.state.session == nil
    }

    // MARK: - Requests

    func requestVirtualScaling() {
        guard canStartVirtualScaling, let plan = virtualPlan, let display = selectedDisplay else { return }
        pendingVirtual = VirtualScalingRequest(
            displayID: display.id, displayName: display.displayName, currentMode: display.currentMode,
            plan: plan, timeout: Int(confirmationTimeout.rounded()))
    }

    func confirmVirtual(_ request: VirtualScalingRequest) {
        pendingVirtual = nil
        guard !isBusy, let display = services.discovery.display(withID: request.displayID) else {
            banner = Banner(kind: .error, title: "\(request.displayName) is no longer connected", message: "Nothing was changed.")
            refreshNow()
            return
        }
        banner = nil
        virtualScaling.confirmationTimeout = confirmationTimeout
        Task { [virtualScaling] in
            await virtualScaling.beginTrial(on: display, plan: request.plan)
        }
    }

    func turnOffVirtualScaling() {
        guard virtualState.session != nil, !virtualScaling.isBusy else { return }
        Task { [virtualScaling] in
            await virtualScaling.turnOff()
        }
    }

    func keepVirtualTrial() {
        guard case .awaitingConfirmation = virtualScaling.state else { return }
        trialActionLabel = "Keeping virtual scaling…"
        virtualScaling.keep()
    }

    func revertVirtualTrial() {
        guard case .awaitingConfirmation = virtualScaling.state else { return }
        trialActionLabel = "Restoring the previous settings…"
        Task { [virtualScaling] in
            await virtualScaling.turnOff(reason: "Reverted by the user")
        }
    }

    // MARK: - Service callbacks

    func virtualStateChanged(_ state: VirtualScalingService.State) {
        virtualState = state
        switch state {
        case .awaitingConfirmation(let session, let deadline):
            trialSession = RecoveryService.Session(
                id: session.id, displayID: session.virtualID, displayKey: session.physicalKey,
                displayName: session.physicalName, previous: session.previousMode ?? session.plan.modeInfo,
                target: session.plan.modeInfo, startedAt: session.startedAt, deadline: deadline,
                verification: session.verification.applyVerification(for: session.plan))
            trialActionLabel = nil
            confirmationStartedAt = Date()
            trialPanels?.show(focusing: session.virtualID)
        case .applying:
            // Countdown expired or Revert pressed: never leave Keep clickable.
            if trialSession != nil, trialActionLabel == nil {
                trialActionLabel = "Restoring the previous settings…"
            }
        case .active, .off:
            if trialSession != nil, services.recovery.state.session == nil {
                trialSession = nil
                confirmationStartedAt = nil
                trialActionLabel = nil
                trialPanels?.close()
            }
        }
        scheduleRefresh()
    }

    func virtualOutcome(_ outcome: VirtualScalingService.Outcome) {
        switch outcome {
        case .kept(let session):
            let verified = session.verification.isVerified(for: session.plan)
            if verified {
                let environment = services.environment
                services.verifications.record(VerificationRecord(
                    displayKey: Self.virtualVerificationKey(session.physicalKey),
                    displayName: "\(session.physicalName) (virtual display)",
                    signature: session.plan.modeInfo.signature, verifiedAt: Date(),
                    osVersion: environment.summary, hardwareModel: environment.hardwareModel ?? "unknown",
                    observedScale: session.verification.screenScale,
                    method: "Virtual display: CGDisplayMirrorsDisplay + CGDisplayCopyDisplayMode + NSScreen.backingScaleFactor"))
            }
            banner = Banner(
                kind: verified ? .success : .warning,
                title: "Kept \(session.plan.target) virtual scaling on \(session.physicalName)",
                message: (verified
                    ? "macOS reports a 2× HiDPI desktop of \(session.plan.points) points. "
                    : "macOS did not fully confirm the HiDPI desktop. ")
                    + "It stays on while ScaleKit runs and is re-applied when ScaleKit starts.")
        case .turnedOff(let session, let reason, let automatic):
            banner = Banner(
                kind: automatic ? .warning : .info,
                title: "Virtual scaling turned off on \(session.physicalName)",
                message: reason + ".")
        case .failed(let message):
            banner = Banner(kind: .error, title: "Virtual scaling could not be applied", message: message)
        case .restoredAtLaunch(let session):
            banner = Banner(
                kind: .info, title: "Re-applied \(session.plan.target) virtual scaling",
                message: "\(session.physicalName) looks like \(session.plan.points) points. Turn it off from the main window or the menu bar.")
        }
        reloadHistory()
        refreshNow()
    }

    func restoreVirtualScalingAtLaunch() async -> String? {
        await virtualScaling.restoreAtLaunch(displays: displays) { [weak self] display in
            self?.virtualRefresh(for: display) ?? display.refreshRate.value ?? 60
        }
    }

    /// The preferred refresh rate when the monitor offers it, otherwise its current rate.
    func virtualRefresh(for display: DisplayInfo) -> Double {
        services.profiles.context(for: display, preferredRefresh: preferredRefresh)?.referenceRefresh
            ?? display.refreshRate.value ?? preferredRefresh
    }

    func handleForVirtualScaling(_ event: DisplayEvent) {
        // The kept monitor came back (power cycle, cable, standby): re-apply.
        if case .reconfigured(_, let changes) = event, changes.contains(.added), !changes.isPreflight,
           virtualState.session == nil, !isBusy,
           let savedKey = virtualScaling.savedPreference?.displayKey,
           !displays.contains(where: { $0.key == savedKey }) {
            // Only when the kept monitor was absent and is now back; never for
            // ScaleKit's own virtual display or after an automatic turn-off.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, virtualState.session == nil, !isBusy else { return }
                let fresh = services.discovery.discover()
                    .filter { !VirtualDisplayScaler.isScaleKitVirtualDisplay(vendorID: $0.identity.vendorID) }
                guard fresh.contains(where: { $0.key == savedKey }) else { return }
                await virtualScaling.restoreSaved(displays: fresh) { [weak self] display in
                    self?.virtualRefresh(for: display) ?? display.refreshRate.value ?? 60
                }
            }
            return
        }
        guard let session = virtualState.session else { return }
        switch event {
        case .systemWillSleep:
            Task { [virtualScaling] in await virtualScaling.systemWillSleep() }
        case .systemDidWake, .screensDidWake:
            Task { [virtualScaling] in await virtualScaling.systemDidWake() }
        case .reconfigured(let displayID, let changes)
            where displayID == session.physicalID && !changes.isPreflight
                && (changes.contains(.removed) || changes.contains(.disabled)):
            Task { [virtualScaling] in await virtualScaling.displayRemoved(displayID) }
        case .reconfigured(_, let changes) where !changes.isPreflight:
            Task { [virtualScaling] in await virtualScaling.checkMirrorAfterReconfiguration() }
        default:
            break
        }
    }
}

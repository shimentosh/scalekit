import AppKit
import ScaleKitCore

/// Review → trial → keep/revert flow, and reactions to display events.
extension AppModel {
    // MARK: - Requesting a change (opens the review sheet; never applies)

    func requestApply() {
        guard let candidate = applyCandidate else {
            if canStartVirtualScaling { requestVirtualScaling() }
            return
        }
        requestChange(candidate.kind, mode: candidate.mode)
    }

    /// Explicit opt-in to one of the closest alternatives of an unsupported profile.
    func requestAlternative(_ assessment: ModeAssessment) {
        guard let evaluation = selectedEvaluation else { return }
        chosenAlternative = assessment.mode
        requestChange(.alternative(desired: evaluation.target, percent: assessment.uiPercent), mode: assessment.mode)
    }

    func requestRevert() {
        guard canRevert, let revertMode else { return }
        requestChange(.revert, mode: revertMode)
    }

    func requestReset() {
        guard canReset, let resetMode else { return }
        requestChange(.reset, mode: resetMode)
    }

    /// From the menu bar extra: select the profile and present the review sheet.
    func chooseFromMenu(displayID: UInt32, target: ScalingTarget) {
        selectDisplay(displayID)
        selectTarget(target)
        requestApply()
    }

    private func requestChange(_ kind: ChangeRequest.Kind, mode: DisplayModeInfo) {
        guard !isBusy, let selected = selectedDisplay else { return }
        // Ordinary mode changes and virtual scaling never overlap: the
        // virtual teardown restores every app-only change of this process.
        if virtualState.session != nil {
            banner = Banner(
                kind: .info, title: "Virtual scaling is on",
                message: "Turn off virtual scaling before changing display modes.")
            return
        }
        // Plan against a fresh read so the review shows the real current state.
        let display = services.discovery.display(withID: selected.id) ?? selected
        let plan = services.configuration.plan(for: display, target: mode)
        pendingChange = ChangeRequest(
            kind: kind, displayID: display.id, displayName: display.displayName, mode: mode, plan: plan,
            timeout: Int(confirmationTimeout.rounded()))
    }

    // MARK: - Starting the trial

    /// Called by the review sheet's Apply button.
    func confirm(_ request: ChangeRequest, acceptRefreshReduction: Bool) {
        pendingChange = nil
        guard !isBusy else { return }
        guard let display = services.discovery.display(withID: request.displayID) else {
            banner = Banner(
                kind: .error, title: "\(request.displayName) is no longer connected",
                message: "Nothing was changed.")
            refreshNow()
            return
        }
        guard display.currentMode?.signature == request.plan.from?.signature else {
            banner = Banner(
                kind: .warning, title: "\(request.displayName) changed while you were reviewing",
                message: "Nothing was changed. Review the change again.")
            refreshNow()
            return
        }
        banner = nil
        services.recovery.confirmationTimeout = confirmationTimeout
        Task { [services] in
            await services.recovery.beginTrial(
                on: display, to: request.mode, acceptRefreshReduction: acceptRefreshReduction)
        }
    }

    // MARK: - Trial confirmation

    func keepTrial() {
        if isVirtualTrial {
            keepVirtualTrial()
            return
        }
        guard services.recovery.state.session != nil else { return }
        trialActionLabel = "Saving to your display preferences…"
        Task { [services] in await services.recovery.keep() }
    }

    func revertTrial() {
        if isVirtualTrial {
            revertVirtualTrial()
            return
        }
        guard services.recovery.state.session != nil else { return }
        trialActionLabel = "Restoring the previous settings…"
        Task { [services] in await services.recovery.revert() }
    }

    /// Keep or Revert is being processed for the session on screen.
    var isResolvingTrial: Bool {
        guard trialSession != nil else { return false }
        if case .applying = trialState { return true }
        return false
    }

    /// Seconds left and the fraction of the countdown remaining.
    func countdown(at date: Date) -> (remaining: TimeInterval, fraction: Double) {
        guard let session = trialSession else { return (0, 0) }
        let remaining = max(0, session.deadline.timeIntervalSince(date))
        let total = max(1, session.deadline.timeIntervalSince(confirmationStartedAt ?? session.startedAt))
        return (remaining, min(1, remaining / total))
    }

    func recoveryStateChanged(_ state: RecoveryService.State) {
        trialState = state
        switch state {
        case .idle:
            trialSession = nil
            confirmationStartedAt = nil
            trialActionLabel = nil
            trialPanels?.close()
        case .applying:
            // While Keep/Revert runs the panels stay up with a progress state.
            break
        case .awaitingConfirmation(let session):
            trialSession = session
            trialActionLabel = nil
            confirmationStartedAt = Date()
            trialPanels?.show(focusing: session.displayID)
        case .finished(let outcome):
            trialSession = nil
            confirmationStartedAt = nil
            trialActionLabel = nil
            trialPanels?.close()
            let key: String? = switch outcome {
            case .kept(let session, _), .reverted(let session, _, _),
                 .abandoned(let session, _), .superseded(let session, _):
                session.displayKey
            case .failed:
                nil
            }
            refreshNow()
            banner = Banner.outcome(outcome) { [weak self] mode in
                self?.describe(mode, displayKey: key) ?? mode.summary
            }
            reloadHistory()
        }
    }

    // MARK: - Display events

    func handle(_ event: DisplayEvent) {
        scheduleRefresh()
        guard let session = services.recovery.state.session else { return }
        switch event {
        case .systemWillSleep:
            Task { [services] in await services.recovery.handle(.systemWillSleep) }
        case .reconfigured(let displayID, let changes) where displayID == session.displayID && !changes.isPreflight:
            if changes.contains(.removed) || changes.contains(.disabled) {
                Task { [services] in await services.recovery.handle(.targetDisplayRemoved) }
            } else if changes.contains(.setMode) {
                checkForExternalModeChange(session)
            }
        default:
            break
        }
    }

    /// Another app or System Settings changed the trial display's mode.
    private func checkForExternalModeChange(_ session: RecoveryService.Session) {
        guard let current = services.modes.currentMode(for: session.displayID),
              current.signature != session.target.signature
        else { return }
        // Re-check shortly after, so a transient read during reconfiguration
        // does not end the trial.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  let active = services.recovery.state.session, active.id == session.id,
                  let mode = services.modes.currentMode(for: session.displayID),
                  mode.signature != session.target.signature
            else { return }
            await services.recovery.handle(.targetDisplayChangedExternally)
        }
    }

    func checkTrialDisplayIsConnected(_ displays: [DisplayInfo]) {
        guard let session = services.recovery.state.session,
              !displays.contains(where: { $0.id == session.displayID })
        else { return }
        Task { [services] in await services.recovery.handle(.targetDisplayRemoved) }
    }
}

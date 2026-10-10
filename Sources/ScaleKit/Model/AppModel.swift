import AppKit
import Observation
import ScaleKitCore
import ScaleKitVirtual

/// The single source of truth for every window, the menu bar extra and the
/// trial panels. Hardware decisions stay in ScaleKitCore; this class only
/// gathers results for presentation and routes user intent through
/// `RecoveryService`.
@Observable
@MainActor
final class AppModel {
    enum DefaultsKey {
        static let preferredRefresh = "preferredRefreshRate"
        static let confirmationTimeout = "confirmationTimeout"
    }

    static let defaultPreferredRefresh = 120.0
    static let defaultConfirmationTimeout = 15.0
    static let timeoutRange: ClosedRange<Double> = 10...60

    @ObservationIgnored let services: ScaleKitServices
    /// EXPERIMENTAL: HiDPI scaling through a virtual display (private API).
    @ObservationIgnored let virtualScaling: VirtualScalingService
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var selectedDisplayKey: String?
    @ObservationIgnored var trialPanels: TrialPanelController?

    // MARK: Settings

    private(set) var preferredRefresh: Double
    private(set) var confirmationTimeout: Double

    // MARK: Displays

    private(set) var displays: [DisplayInfo] = []
    private(set) var targetMatch: MonitorMatch?
    private(set) var evaluationsByDisplay: [UInt32: [ProfileEvaluation]] = [:]
    private(set) var availableRefreshRates: [Double] = []
    var selectedDisplayID: UInt32?

    // MARK: Profile selection

    var selectedTarget = ScalingTarget(percent: 150)
    /// An alternative mode the user explicitly opted into for an unsupported profile.
    var chosenAlternative: DisplayModeInfo?

    // MARK: Details for the selected display

    var hiDPIStatus: HiDPIStatus?
    var hiDPIAvailability: HiDPIAvailability?
    var recommendation: RecommendationSummary?
    var backup: DisplayStateRecord?
    var revertMode: DisplayModeInfo?
    var referenceRefresh: Double?
    var allModes: [DisplayModeInfo] = []
    var desktopModes: [DisplayModeInfo] = []
    var verifiedSignatures: Set<ModeSignature> = []
    var verificationRecords: [VerificationRecord] = []

    // MARK: Change flow

    /// Drives the review sheet. Nothing is applied while this is set.
    var pendingChange: ChangeRequest?
    var trialState: RecoveryService.State = .idle
    /// The session awaiting confirmation (kept while Keep/Revert is in progress).
    var trialSession: RecoveryService.Session?
    var confirmationStartedAt: Date?
    /// "Saving…" / "Restoring…" while Keep or Revert is processed.
    var trialActionLabel: String?
    var isRecoveringAfterLaunch = false
    var banner: Banner?

    // MARK: Virtual-display scaling (experimental)

    var virtualState: VirtualScalingService.State = .off
    /// Drives the virtual-scaling review sheet. Nothing is applied while this is set.
    var pendingVirtual: VirtualScalingRequest?

    // MARK: Advanced

    var historyEntries: [HistoryEntry] = []
    var diagnosticReport: DiagnosticReport?
    var diagnosticMarkdown = ""
    var isGeneratingReport = false
    var reportMessage: String?

    init() {
        services = ScaleKitServices.live()
        virtualScaling = VirtualScalingService(
            hardware: services.hardware, paths: services.paths, history: services.history)
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            DefaultsKey.preferredRefresh: Self.defaultPreferredRefresh,
            DefaultsKey.confirmationTimeout: Self.defaultConfirmationTimeout,
        ])
        let refresh = defaults.double(forKey: DefaultsKey.preferredRefresh)
        preferredRefresh = refresh > 0 ? refresh : Self.defaultPreferredRefresh
        confirmationTimeout = Self.clampTimeout(defaults.double(forKey: DefaultsKey.confirmationTimeout))
        trialPanels = TrialPanelController(model: self)
    }

    static func clampTimeout(_ value: Double) -> Double {
        min(max(value, timeoutRange.lowerBound), timeoutRange.upperBound)
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        services.recovery.confirmationTimeout = confirmationTimeout
        services.recovery.onStateChange = { [weak self] state in
            self?.recoveryStateChanged(state)
        }
        virtualScaling.confirmationTimeout = confirmationTimeout
        virtualScaling.onStateChange = { [weak self] state in
            self?.virtualStateChanged(state)
        }
        virtualScaling.onOutcome = { [weak self] outcome in
            self?.virtualOutcome(outcome)
        }
        services.events.addHandler { [weak self] event in
            self?.handle(event)
            self?.handleForVirtualScaling(event)
        }
        services.events.start()
        refreshNow()
        reloadHistory()

        isRecoveringAfterLaunch = true
        Task { [weak self] in
            guard let self else { return }
            let report = await services.recovery.recoverAfterLaunch(displays: displays)
            let virtualMessage = await restoreVirtualScalingAtLaunch()
            isRecoveringAfterLaunch = false
            if let virtualMessage, report == nil {
                banner = Banner(kind: .info, title: "Virtual scaling", message: virtualMessage)
            }
            guard let report else { return }
            let kind: Banner.Kind = switch report.assessment {
            case .trialModeStillActive, .displayMissing: .warning
            default: .info
            }
            banner = Banner(kind: kind, title: "Checked an unfinished change", message: report.message)
            refreshNow()
            reloadHistory()
        }
    }

    func prepareForTermination() {
        services.recovery.prepareForTermination()
        virtualScaling.prepareForTermination()
        services.events.stop()
    }

    // MARK: - Settings

    func updatePreferredRefresh(_ value: Double) {
        guard value > 0, value != preferredRefresh else { return }
        preferredRefresh = value
        refreshNow()
    }

    func updateConfirmationTimeout(_ value: Double) {
        confirmationTimeout = Self.clampTimeout(value)
        if !services.recovery.isBusy {
            services.recovery.confirmationTimeout = confirmationTimeout
        }
        if !virtualScaling.isBusy {
            virtualScaling.confirmationTimeout = confirmationTimeout
        }
    }

    // MARK: - Derived state

    var selectedDisplay: DisplayInfo? {
        displays.first { $0.id == selectedDisplayID }
    }

    var evaluations: [ProfileEvaluation] {
        selectedDisplayID.flatMap { evaluationsByDisplay[$0] } ?? []
    }

    var selectedEvaluation: ProfileEvaluation? {
        evaluations.first { $0.target == selectedTarget }
    }

    /// A change is being applied, awaiting confirmation, or launch recovery is running.
    var isBusy: Bool {
        if isRecoveringAfterLaunch || virtualScaling.isBusy { return true }
        switch trialState {
        case .applying, .awaitingConfirmation: return true
        case .idle, .finished: return false
        }
    }

    var chosenAlternativeAssessment: ModeAssessment? {
        guard let chosen = chosenAlternative else { return nil }
        return selectedEvaluation?.alternatives.first { $0.mode.signature == chosen.signature }
    }

    /// What Apply… would change to right now, if anything.
    var applyCandidate: (mode: DisplayModeInfo, kind: ChangeRequest.Kind)? {
        guard let evaluation = selectedEvaluation, let display = selectedDisplay else { return nil }
        let current = display.currentMode?.signature
        if let selection = evaluation.selection {
            guard selection.mode.signature != current else { return nil }
            return (mode: selection.mode, kind: ChangeRequest.Kind.profile(evaluation.target))
        }
        if let alternative = chosenAlternativeAssessment, alternative.mode.signature != current {
            return (
                mode: alternative.mode,
                kind: ChangeRequest.Kind.alternative(desired: evaluation.target, percent: alternative.uiPercent))
        }
        return nil
    }

    /// The clean 100% mode at the reference refresh rate.
    var resetMode: DisplayModeInfo? {
        evaluations.first { $0.target.percent == 100 }?.selection?.mode
    }

    var canApply: Bool {
        if applyCandidate == nil { return canStartVirtualScaling }
        return !isBusy && !isVirtuallyScaled(selectedDisplay)
    }

    var canRevert: Bool {
        guard !isBusy, !isVirtuallyScaled(selectedDisplay), let revertMode else { return false }
        return revertMode.signature != selectedDisplay?.currentMode?.signature
    }

    var canReset: Bool {
        guard !isBusy, !isVirtuallyScaled(selectedDisplay), let resetMode else { return false }
        return resetMode.signature != selectedDisplay?.currentMode?.signature
    }

    /// Why Apply… is (or is not) available, in one line.
    var applyHint: String {
        guard let evaluation = selectedEvaluation else { return "Select a display and an interface size." }
        if let session = virtualSession(for: selectedDisplay) {
            return session.plan.target == evaluation.target
                ? "\(evaluation.target) is active through a virtual display."
                : "Turn off \(session.plan.target) virtual scaling to choose another size."
        }
        if let candidate = applyCandidate {
            return "Apply switches to \(candidate.mode.summary)."
        }
        if let plan = virtualPlan {
            return "Apply tries \(plan.target) with a virtual display (experimental): \(plan.points) pt HiDPI."
        }
        switch evaluation.status {
        case .unsupported:
            return chosenAlternative == nil
                ? "\(evaluation.target) is unsupported. Choose a closest alternative to continue."
                : "The chosen alternative is already active."
        case .unknown:
            return "There is not enough information to apply \(evaluation.target)."
        default:
            return "\(evaluation.target) is already active."
        }
    }

    // MARK: - Refreshing

    /// Coalesces bursts of display events into one refresh.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil

        // ScaleKit's own virtual display is an implementation detail of
        // virtual scaling, not a monitor the user should manage.
        let found = services.discovery.discover()
            .filter { !VirtualDisplayScaler.isScaleKitVirtualDisplay(vendorID: $0.identity.vendorID) }
        displays = found
        targetMatch = DisplayDiscoveryService.match(.asusVG34WQML5A, in: found)
        var evaluations: [UInt32: [ProfileEvaluation]] = [:]
        var rates: Set<Int> = [60, 120, Int(preferredRefresh.rounded())]
        for display in found {
            evaluations[display.id] = services.profiles.evaluations(for: display, preferredRefresh: preferredRefresh)
            for mode in services.modes.desktopModes(for: display.id) where mode.hasNativeFlag && mode.refreshRate > 0 {
                rates.insert(Int(mode.refreshRate.rounded()))
            }
        }
        evaluationsByDisplay = evaluations
        availableRefreshRates = rates.sorted().map(Double.init)
        verificationRecords = services.verifications.records()

        if let id = selectedDisplayID, found.contains(where: { $0.id == id }) {
            updateSelectedDisplayDetails()
        } else if let key = selectedDisplayKey, let same = found.first(where: { $0.key == key }) {
            // Same monitor, new CoreGraphics ID after a reconnect.
            selectedDisplayID = same.id
            updateSelectedDisplayDetails()
        } else if let id = defaultDisplayID(in: found) {
            selectDisplay(id)
        } else {
            selectedDisplayID = nil
            updateSelectedDisplayDetails()
        }
        checkTrialDisplayIsConnected(found)
    }

    func reloadHistory() {
        historyEntries = services.history.entries()
    }

    /// The ASUS VG34WQML5A when connected, otherwise the main display.
    private func defaultDisplayID(in displays: [DisplayInfo]) -> UInt32? {
        if let match = DisplayDiscoveryService.match(.asusVG34WQML5A, in: displays) { return match.displayID }
        return displays.first(where: \.isMain)?.id ?? displays.first?.id
    }

    private func updateSelectedDisplayDetails() {
        guard let display = selectedDisplay else {
            hiDPIStatus = nil
            hiDPIAvailability = nil
            recommendation = nil
            backup = nil
            revertMode = nil
            referenceRefresh = nil
            allModes = []
            desktopModes = []
            verifiedSignatures = []
            chosenAlternative = nil
            return
        }
        hiDPIStatus = services.hiDPI.status(for: display.id)
        hiDPIAvailability = services.hiDPI.availability(for: display.id)
        backup = services.backups.backup(for: display.key)
        revertMode = backup.flatMap { services.modes.mode(matching: $0.mode.signature, for: display.id) }
        referenceRefresh = services.profiles.context(for: display, preferredRefresh: preferredRefresh)?.referenceRefresh
        allModes = services.modes.allModes(for: display.id)
        desktopModes = DisplayModeService.desktopModes(from: allModes)
        verifiedSignatures = services.verifications.verifiedSignatures(for: display.key)
        if chosenAlternative != nil && chosenAlternativeAssessment == nil {
            chosenAlternative = nil
        }
        recommendation = makeRecommendation(for: display)
    }

    // MARK: - Selection

    func selectDisplay(_ id: UInt32) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let changed = id != selectedDisplayID
        selectedDisplayID = id
        selectedDisplayKey = display.key
        if changed {
            chosenAlternative = nil
            selectedTarget = initialTarget(for: display)
        }
        updateSelectedDisplayDetails()
    }

    func selectTarget(_ target: ScalingTarget) {
        guard target != selectedTarget else { return }
        selectedTarget = target
        chosenAlternative = nil
        recommendation = selectedDisplay.flatMap { makeRecommendation(for: $0) }
    }

    /// 150% when the display is at 100%, otherwise the current profile.
    private func initialTarget(for display: DisplayInfo) -> ScalingTarget {
        guard let scale = display.currentUIScale else { return ScalingTarget(percent: 150) }
        if abs(scale - 1) < 0.03 { return ScalingTarget(percent: 150) }
        if let current = evaluationsByDisplay[display.id]?.first(where: \.isCurrent) { return current.target }
        return ScalingTarget.standard.min { abs($0.factor - scale) < abs($1.factor - scale) } ?? ScalingTarget(percent: 150)
    }

    // MARK: - Recommendation

    private func makeRecommendation(for display: DisplayInfo) -> RecommendationSummary? {
        let evaluations = evaluationsByDisplay[display.id] ?? []
        guard let result = services.profiles.recommendation(
            for: display, desired: selectedTarget, preferredRefresh: preferredRefresh, evaluations: evaluations)
        else { return nil }
        guard var assessment = result.assessment else {
            return RecommendationSummary(
                desired: result.desired, profile: nil, assessment: nil, status: nil,
                meetsAllCriteria: false, headline: "No recommendation", reason: result.headline)
        }

        var profile = result.profile
        // The engine scores every refresh rate at or above the reference
        // equally, so it can rank the same picture at a different rate first.
        // Present the profile's own mode, which uses the reference rate.
        if profile == nil,
           let match = evaluations.first(where: { evaluation in
               guard let selection = evaluation.selection else { return false }
               return selection.mode.logical == assessment.mode.logical && selection.mode.pixels == assessment.mode.pixels
           }),
           let selection = match.selection {
            profile = match.target
            assessment = services.profiles.assess(
                selection.mode, on: display, desired: selectedTarget, preferredRefresh: preferredRefresh) ?? selection
        }

        let status = profile.flatMap { target in evaluations.first { $0.target == target }?.status } ?? assessment.status
        let meetsAll = assessment.isClean && !assessment.refresh.isReduction
        let name = profile.map(\.description) ?? "\(assessment.uiPercent)%"
        let headline = "\(name) · \(assessment.mode.summary)"

        var reason: String
        if meetsAll, let native = display.nativeResolution.value {
            reason = "Keeps native \(native) output, \(assessment.renderingPath.label.lowercased()), "
                + "\(assessment.mode.refreshLabel) and the panel's \(native.aspectLabel) shape."
            if let profile, profile != selectedTarget {
                reason = "Closest sharp option to \(selectedTarget). " + reason
            }
        } else {
            reason = result.headline
        }
        return RecommendationSummary(
            desired: selectedTarget, profile: profile, assessment: assessment, status: status,
            meetsAllCriteria: meetsAll, headline: headline, reason: reason)
    }

    // MARK: - Helpers for views

    /// "200% · 1720 × 720 HiDPI @ 120 Hz" when the panel size is known.
    func describe(_ mode: DisplayModeInfo, displayKey: String?) -> String {
        guard let native = displays.first(where: { $0.key == displayKey })?.nativeResolution.value else {
            return mode.summary
        }
        return "\(Format.percent(RecommendationEngine.uiScale(of: mode, native: native))) · \(mode.summary)"
    }

    func currentMode(for displayID: UInt32) -> DisplayModeInfo? {
        services.modes.currentMode(for: displayID)
    }
}

import Foundation

/// Wires the services together. The app, the CLI and tests each build one.
@MainActor
public final class ScaleKitServices {
    public let paths: AppPaths
    public let environment: EnvironmentInfo
    public let hardware: DisplayHardware
    public let modes: DisplayModeService
    public let hiDPI: HiDPIDetectionService
    public let discovery: DisplayDiscoveryService
    public let verifications: VerificationStore
    public let profiles: ScalingProfileService
    public let configuration: DisplayConfigurationService
    public let backups: ConfigurationBackupService
    public let history: HistoryStore
    public let recovery: RecoveryService
    public let events: DisplayEventMonitor
    public let diagnostics: DiagnosticsService

    public init(
        hardware: DisplayHardware,
        paths: AppPaths = .standard(),
        guardLauncher: GuardLauncher? = ProcessGuardLauncher.locate(),
        environment: EnvironmentInfo = .current()
    ) {
        self.paths = paths
        self.environment = environment
        self.hardware = hardware
        modes = DisplayModeService(hardware: hardware)
        hiDPI = HiDPIDetectionService(hardware: hardware, modes: modes)
        discovery = DisplayDiscoveryService(hardware: hardware, modes: modes)
        verifications = VerificationStore(fileURL: paths.verificationsFile)
        profiles = ScalingProfileService(modes: modes, verifications: verifications)
        configuration = DisplayConfigurationService(hardware: hardware, modes: modes)
        backups = ConfigurationBackupService(fileURL: paths.backupFile)
        history = HistoryStore(fileURL: paths.historyFile)
        recovery = RecoveryService(
            configuration: configuration, modes: modes, backups: backups, history: history,
            verifications: verifications, journalURL: paths.trialJournalFile,
            guardLauncher: guardLauncher, guardLogURL: paths.guardLogFile, environment: environment)
        events = DisplayEventMonitor()
        diagnostics = DiagnosticsService(
            discovery: discovery, modes: modes, hiDPI: hiDPI, profiles: profiles, verifications: verifications)
    }

    public static func live() -> ScaleKitServices {
        ScaleKitServices(hardware: LiveDisplayHardware())
    }
}

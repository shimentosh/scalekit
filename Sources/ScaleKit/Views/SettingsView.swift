import ScaleKitCore
import ServiceManagement
import SwiftUI

/// ⌘, — ScaleKit's preferences.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.DefaultsKey.preferredRefresh) private var preferredRefresh = AppModel.defaultPreferredRefresh
    @AppStorage(AppModel.DefaultsKey.confirmationTimeout) private var confirmationTimeout = AppModel.defaultConfirmationTimeout

    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginItemError: String?

    private var refreshChoices: [Double] {
        var rates = model.availableRefreshRates
        if !rates.contains(where: { RefreshRate.isSame($0, preferredRefresh) }) {
            rates.append(preferredRefresh)
        }
        return rates.sorted()
    }

    var body: some View {
        Form {
            Section {
                Picker("Preferred refresh rate", selection: $preferredRefresh) {
                    ForEach(refreshChoices, id: \.self) { rate in
                        Text(RefreshRate.label(rate)).tag(rate)
                    }
                }
            } footer: {
                Text("Profiles use this rate when the display offers it; otherwise they keep the current rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Confirmation timeout") {
                    HStack(spacing: 10) {
                        Slider(value: $confirmationTimeout, in: AppModel.timeoutRange, step: 5)
                            .frame(width: 180)
                        Text("\(Int(confirmationTimeout)) s")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            } footer: {
                Text("How long you have to keep a change before ScaleKit reverts it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open ScaleKit at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
            } footer: {
                Text(loginItemError
                    ?? "Virtual-display scaling stays on only while ScaleKit runs. Opening ScaleKit at login re-applies a size you kept.")
                    .font(.caption)
                    .foregroundStyle(loginItemError == nil ? .secondary : Color.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: preferredRefresh, initial: true) { _, value in
            model.updatePreferredRefresh(value)
        }
        .onChange(of: confirmationTimeout, initial: true) { _, value in
            model.updateConfirmationTimeout(value)
        }
    }

    /// Uses SMAppService, which needs ScaleKit to run from its app bundle.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Could not change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

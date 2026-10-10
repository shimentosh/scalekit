import ScaleKitCore
import SwiftUI

/// Every fact ScaleKit knows about the selected display, with provenance.
struct DisplayInfoTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let display = model.selectedDisplay {
            Form {
                Section("Identity") {
                    FactRow("Name", fact: display.name) { $0 }
                    FactRow("Manufacturer", fact: display.manufacturer) { $0 }
                    FactRow(label: "Role", value: role(display), provenance: .measured,
                            source: "CGDisplayIsMain / CGDisplayIsBuiltin / CGDisplayIsActive / CGDisplayIsInMirrorSet")
                    FactRow("Connection", fact: display.connection) { $0 }
                    if let match = model.targetMatch, match.displayID == display.id {
                        FactRow(label: "Recognised as", value: "\(match.monitorName) (\(match.confidence.label) confidence)",
                                provenance: .inferred, source: match.reasons.joined(separator: "; "))
                    }
                }

                Section("Panel") {
                    FactRow("Native resolution", fact: display.nativeResolution) { "\($0)" }
                    FactRow("Physical size", fact: display.physicalSize) { $0.description }
                    FactRow("Pixel density", fact: display.pixelDensity) { String(format: "%.0f PPI", $0) }
                }

                Section("Current mode") {
                    FactRow("Looks like", fact: display.logicalResolution) { "\($0) pt" }
                    FactRow("Rendered backing store", fact: display.framebufferResolution) { "\($0) px" }
                    FactRow("Physical output", fact: display.physicalOutput) { "\($0) px" }
                    FactRow("Backing scale factor", fact: display.backingScaleFactor) { Format.scale($0) }
                    FactRow("Refresh rate", fact: display.refreshRate) { RefreshRate.label($0) }
                    FactRow("Max frames per second", fact: display.maximumFramesPerSecond) { "\($0)" }
                    if let status = model.hiDPIStatus {
                        FactRow(label: "HiDPI", value: "\(status.label) · \(status.confidence.label) confidence",
                                provenance: status.isActive == nil ? .unavailable : .measured, source: status.explanation)
                    }
                    if let mode = display.currentMode {
                        FactRow(label: "Active mode", value: "ID \(mode.modeID) · \(mode.flags.hexDescription)",
                                provenance: .measured,
                                source: "CGDisplayModeGetIODisplayModeID / GetIOFlags: \(mode.flags.names.joined(separator: ", "))")
                    }
                    if let availability = model.hiDPIAvailability {
                        FactRow(label: "HiDPI modes offered", value: "\(availability.hiDPIModeCount)",
                                provenance: .measured, source: availability.summary)
                    }
                }

                Section("Identifiers") {
                    FactRow(label: "CoreGraphics display ID", value: "\(display.id)", provenance: .measured,
                            source: "CGGetOnlineDisplayList — valid only while connected")
                    FactRow(label: "Display UUID", value: display.identity.uuid ?? "—",
                            provenance: display.identity.uuid == nil ? .unavailable : .measured,
                            source: "CGDisplayCreateUUIDFromDisplayID")
                    FactRow(label: "Vendor / product", value: display.identity.hexDescription, provenance: .measured,
                            source: "CGDisplayVendorNumber / CGDisplayModelNumber")
                    FactRow(label: "Serial number", value: "\(display.identity.serialNumber)", provenance: .measured,
                            source: "CGDisplaySerialNumber (0 when the monitor does not report one)")
                    FactRow(label: "Storage key", value: display.key, provenance: .inferred,
                            source: "UUID, or vendor-product-serial when no UUID is available")
                }

                Section("Registry attributes (undocumented)") {
                    if let registry = display.registry {
                        registryRows(registry)
                    } else {
                        Text("No IORegistry attributes matched this display.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Display Selected", systemImage: "display")
        }
    }

    @ViewBuilder
    private func registryRows(_ registry: RegistryDisplayAttributes) -> some View {
        let source = "IORegistry DisplayAttributes (undocumented key)"
        row("Product name", registry.productName, source)
        row("Manufacturer code", registry.manufacturerCode, source)
        row("Legacy manufacturer ID", registry.legacyManufacturerID.map { String(format: "0x%04X", $0) }, source)
        row("Product ID", registry.productID.map { String(format: "0x%04X", $0) }, source)
        row("Transport (Mac side)", registry.transportUpstream, "IORegistry Transport key (undocumented)")
        row("Transport (monitor side)", registry.transportDownstream, "IORegistry Transport key (undocumented)")
        row("Refresh range", refreshRange(registry), source)
        row("Variable refresh", registry.supportsVariableRefreshRate.map { $0 ? "Supported" : "Not supported" }, source)
        row("HDR", registry.supportsHDR.map { $0 ? "Supported (PQ)" : "Not supported" }, source)
        row("Manufactured", manufactured(registry), source)
    }

    private func row(_ label: String, _ value: String?, _ source: String) -> FactRow {
        FactRow(label: label, value: value ?? "—", provenance: value == nil ? .unavailable : .inferred, source: source)
    }

    private func refreshRange(_ registry: RegistryDisplayAttributes) -> String? {
        switch (registry.minimumRefreshRate, registry.maximumRefreshRate) {
        case let (min?, max?): "\(Int(min))–\(Int(max)) Hz"
        case let (nil, max?): "up to \(Int(max)) Hz"
        case let (min?, nil): "from \(Int(min)) Hz"
        default: nil
        }
    }

    private func manufactured(_ registry: RegistryDisplayAttributes) -> String? {
        guard let year = registry.yearOfManufacture else { return nil }
        return registry.weekOfManufacture.map { "Week \($0), \(year)" } ?? "\(year)"
    }

    private func role(_ display: DisplayInfo) -> String {
        var parts = [display.isMain ? "Main" : "Secondary", display.isBuiltin ? "built-in" : "external"]
        if !display.isActive { parts.append("inactive") }
        if display.isInMirrorSet { parts.append("mirrored") }
        return parts.joined(separator: ", ")
    }
}

/// A fact with its value, provenance chip and source as secondary text.
struct FactRow: View {
    let label: String
    let value: String
    let provenance: Provenance
    let source: String

    init(label: String, value: String, provenance: Provenance, source: String) {
        self.label = label
        self.value = value
        self.provenance = provenance
        self.source = source
    }

    init<T>(_ label: String, fact: Fact<T>, format: (T) -> String) {
        self.init(label: label, value: Format.value(fact, format), provenance: fact.provenance, source: fact.source)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(value)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                ProvenanceChip(provenance: provenance, source: source)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(source)
    }
}

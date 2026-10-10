import Foundation
import os

/// Structured logging. View with:
/// `log stream --predicate 'subsystem == "com.shimantoneer.ScaleKit"'`
public enum Log {
    public static let subsystem = "com.shimantoneer.ScaleKit"
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let configuration = Logger(subsystem: subsystem, category: "configuration")
    public static let recovery = Logger(subsystem: subsystem, category: "recovery")
    public static let events = Logger(subsystem: subsystem, category: "events")
    public static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let virtual = Logger(subsystem: subsystem, category: "virtual")
}

/// Where ScaleKit keeps its local files. Nothing is ever uploaded.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/ScaleKit`, or `$SCALEKIT_SUPPORT_DIR` when set.
    public static func standard() -> AppPaths {
        if let override = ProcessInfo.processInfo.environment["SCALEKIT_SUPPORT_DIR"], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(root: base.appendingPathComponent("ScaleKit", isDirectory: true))
    }

    public var backupFile: URL { root.appendingPathComponent("backups.json") }
    public var historyFile: URL { root.appendingPathComponent("history.json") }
    public var verificationsFile: URL { root.appendingPathComponent("verifications.json") }
    public var trialJournalFile: URL { root.appendingPathComponent("trial.json") }
    public var guardLogFile: URL { root.appendingPathComponent("guard.log") }
    /// Journal for virtual-display scaling trials (watched by ScaleKitGuard).
    public var virtualTrialJournalFile: URL { root.appendingPathComponent("virtual-trial.json") }
    /// The virtual-display scaling the user kept, re-applied at launch.
    public var virtualScalingFile: URL { root.appendingPathComponent("virtual-scaling.json") }
    public var reportsDirectory: URL { root.appendingPathComponent("Reports", isDirectory: true) }
}

/// Reads and writes one Codable value as a JSON file, atomically.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONCoding.encoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The Mac and OS that a result was obtained on.
public struct EnvironmentInfo: Codable, Sendable, Equatable {
    public var macOSVersion: String
    public var macOSBuild: String?
    public var hardwareModel: String?
    public var chip: String?
    public var memoryGB: Int?
    public var architecture: String

    public init(
        macOSVersion: String, macOSBuild: String?, hardwareModel: String?, chip: String?,
        memoryGB: Int?, architecture: String
    ) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.hardwareModel = hardwareModel
        self.chip = chip
        self.memoryGB = memoryGB
        self.architecture = architecture
    }

    public static func current() -> EnvironmentInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var versionString = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { versionString += ".\(version.patchVersion)" }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return EnvironmentInfo(
            macOSVersion: versionString,
            macOSBuild: Sysctl.string("kern.osversion"),
            hardwareModel: Sysctl.string("hw.model"),
            chip: Sysctl.string("machdep.cpu.brand_string"),
            memoryGB: Sysctl.int64("hw.memsize").map { Int($0 / 1_073_741_824) },
            architecture: architecture
        )
    }

    /// For example "macOS 27.0 (26A428) · Mac16,10 · Apple M4".
    public var summary: String {
        var parts = ["macOS \(macOSVersion)\(macOSBuild.map { " (\($0))" } ?? "")"]
        if let hardwareModel { parts.append(hardwareModel) }
        if let chip { parts.append(chip) }
        return parts.joined(separator: " · ")
    }
}

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func int64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

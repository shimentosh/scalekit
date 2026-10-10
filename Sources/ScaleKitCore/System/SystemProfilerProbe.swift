import Foundation

/// One display as described by `system_profiler SPDisplaysDataType -json`.
public struct SystemProfilerDisplay: Codable, Sendable, Equatable {
    public var displayID: UInt32?
    public var name: String?
    /// `_spdisplays_pixels`, e.g. "3440 x 1440".
    public var pixels: String?
    /// `_spdisplays_resolution`, e.g. "1720 x 720 @ 120.00Hz".
    public var resolution: String?

    public init(displayID: UInt32?, name: String?, pixels: String?, resolution: String?) {
        self.displayID = displayID
        self.name = name
        self.pixels = pixels
        self.resolution = resolution
    }

    public var summary: String {
        "pixels \(pixels ?? "?") · UI looks like \(resolution ?? "?")"
    }
}

/// A secondary, independent view of the active display configuration.
///
/// `system_profiler` is a supported Apple tool, but its JSON keys are not
/// documented, so results are only used as corroborating evidence.
public enum SystemProfilerProbe {
    /// Returns nil if the tool fails or does not finish within `timeout` seconds.
    /// The timeout matters: system_profiler can stall while displays reconfigure.
    public static func run(timeout: TimeInterval = 6) async -> [SystemProfilerDisplay]? {
        let data: Data? = await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPDisplaysDataType", "-json"]
            let pipe = Pipe()
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                buffer.append(handle.availableData)
            }
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                return nil
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                Log.diagnostics.notice("system_profiler timed out after \(timeout) s")
                return nil
            }
            if let rest = try? pipe.fileHandleForReading.readToEnd() { buffer.append(rest) }
            return process.terminationStatus == 0 ? buffer.data : nil
        }.value
        return data.flatMap(parse)
    }

    public static func parse(_ data: Data) -> [SystemProfilerDisplay]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpus = root["SPDisplaysDataType"] as? [[String: Any]]
        else { return nil }
        return gpus.flatMap { gpu -> [SystemProfilerDisplay] in
            let displays = gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? []
            return displays.map { display in
                SystemProfilerDisplay(
                    displayID: (display["_spdisplays_displayID"] as? String).flatMap { UInt32($0) },
                    name: display["_name"] as? String,
                    pixels: display["_spdisplays_pixels"] as? String,
                    resolution: display["_spdisplays_resolution"] as? String
                )
            }
        }
    }
}

/// Collects pipe output delivered on a background queue.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { storage.append(chunk) }
    }

    var data: Data { lock.withLock { storage } }
}

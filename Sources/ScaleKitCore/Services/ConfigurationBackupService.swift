import Foundation

/// Saves the mode each display was in before ScaleKit changed it.
@MainActor
public final class ConfigurationBackupService {
    private let store: JSONFileStore<[String: DisplayStateRecord]>
    private let now: () -> Date

    public init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.store = JSONFileStore(url: fileURL)
        self.now = now
    }

    /// Captures the current state of `display`. Fails if it has no current mode.
    public func capture(_ display: DisplayInfo) -> DisplayStateRecord? {
        display.currentMode.map {
            DisplayStateRecord(
                displayKey: display.key, displayID: display.id, displayName: display.displayName,
                mode: $0, capturedAt: now())
        }
    }

    /// Writes the backup to disk. Callers must not change the display if this throws.
    public func save(_ record: DisplayStateRecord) throws {
        var all = (try? store.load()) ?? [:]
        all[record.displayKey] = record
        try store.save(all)
        Log.persistence.info("Saved backup for \(record.displayName, privacy: .public): \(record.mode.summary, privacy: .public)")
    }

    public func backup(for displayKey: String) -> DisplayStateRecord? {
        (try? store.load())?[displayKey]
    }

    public func allBackups() -> [DisplayStateRecord] {
        ((try? store.load()) ?? [:]).values.sorted { $0.capturedAt > $1.capturedAt }
    }
}

/// Append-only log of configuration changes, capped to recent entries.
@MainActor
public final class HistoryStore {
    private let store: JSONFileStore<[HistoryEntry]>
    private let limit: Int

    public init(fileURL: URL, limit: Int = 200) {
        self.store = JSONFileStore(url: fileURL)
        self.limit = limit
    }

    public func append(_ entry: HistoryEntry) {
        var entries = (try? store.load()) ?? []
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        do {
            try store.save(entries)
        } catch {
            Log.persistence.error("Could not write history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Newest first.
    public func entries() -> [HistoryEntry] {
        ((try? store.load()) ?? []).reversed()
    }
}

/// Records of modes that ScaleKit applied and read back on this Mac.
@MainActor
public final class VerificationStore {
    private let store: JSONFileStore<[VerificationRecord]>

    public init(fileURL: URL) {
        self.store = JSONFileStore(url: fileURL)
    }

    public func record(_ record: VerificationRecord) {
        var records = (try? store.load()) ?? []
        records.removeAll { $0.displayKey == record.displayKey && $0.signature == record.signature }
        records.append(record)
        do {
            try store.save(records)
        } catch {
            Log.persistence.error("Could not write verification record: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func records() -> [VerificationRecord] {
        (try? store.load()) ?? []
    }

    public func verifiedSignatures(for displayKey: String) -> Set<ModeSignature> {
        Set(records().filter { $0.displayKey == displayKey }.map(\.signature))
    }
}

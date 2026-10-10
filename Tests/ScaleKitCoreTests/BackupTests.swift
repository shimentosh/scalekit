import Foundation
import Testing
@testable import ScaleKitCore

@MainActor
@Suite("Configuration backup", .serialized)
struct BackupTests {
    private func record(_ fixture: MonitorFixture, modeID: Int32, at date: Date = Fixtures.fixedDate) -> DisplayStateRecord {
        DisplayStateRecord(
            displayKey: fixture.key, displayID: fixture.displayID, displayName: fixture.name,
            mode: fixture.mode(modeID), capturedAt: date)
    }

    @Test("Capture records the current mode under the display's persistent key")
    func capture() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let service = ConfigurationBackupService(fileURL: tmp.file("backups.json"), now: { Fixtures.fixedDate })
        let captured = try #require(service.capture(Fixtures.asus.info()))
        #expect(captured.displayKey == Fixtures.asus.key)
        #expect(captured.displayID == 3)
        #expect(captured.displayName == "VG34WQML5A")
        #expect(captured.mode.modeID == 119)
        #expect(captured.capturedAt == Fixtures.fixedDate)
    }

    @Test("Capture fails when the display reports no current mode")
    func captureWithoutMode() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let service = ConfigurationBackupService(fileURL: tmp.file("backups.json"))
        #expect(service.capture(Fixtures.noModes.info()) == nil)
    }

    @Test("Backups are saved and loaded per display")
    func perDisplay() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let url = tmp.file("backups.json")
        let service = ConfigurationBackupService(fileURL: url)
        try service.save(record(Fixtures.asus, modeID: 119))
        try service.save(record(Fixtures.msi, modeID: 63, at: Fixtures.fixedDate.addingTimeInterval(60)))

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(service.backup(for: Fixtures.asus.key)?.mode.modeID == 119)
        #expect(service.backup(for: Fixtures.msi.key)?.mode.modeID == 63)
        #expect(service.backup(for: "unknown-display") == nil)
        #expect(service.allBackups().map(\.displayID) == [1, 3], "newest first")

        // A second instance reads the same file.
        let reopened = ConfigurationBackupService(fileURL: url)
        #expect(reopened.backup(for: Fixtures.asus.key) == record(Fixtures.asus, modeID: 119))
    }

    @Test("Saving again for the same display overwrites only that display's backup")
    func overwrite() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let service = ConfigurationBackupService(fileURL: tmp.file("backups.json"))
        try service.save(record(Fixtures.asus, modeID: 119))
        try service.save(record(Fixtures.msi, modeID: 63))
        try service.save(record(Fixtures.asus, modeID: 80))
        #expect(service.backup(for: Fixtures.asus.key)?.mode.modeID == 80)
        #expect(service.backup(for: Fixtures.msi.key)?.mode.modeID == 63)
        #expect(service.allBackups().count == 2)
    }

    @Test("Saving throws when the directory cannot be created")
    func unwritable() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let directory = try tmp.unwritableDirectory()
        let service = ConfigurationBackupService(fileURL: directory.appendingPathComponent("backups.json"))
        #expect(throws: (any Error).self) {
            try service.save(record(Fixtures.asus, modeID: 119))
        }
        #expect(service.backup(for: Fixtures.asus.key) == nil)
        #expect(service.allBackups().isEmpty)
    }

    @Test("Saving throws when the backup file path is occupied by a directory")
    func occupiedPath() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let url = tmp.file("backups.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let service = ConfigurationBackupService(fileURL: url)
        #expect(throws: (any Error).self) {
            try service.save(record(Fixtures.asus, modeID: 119))
        }
    }

    @Test("A corrupt backup file reads as empty and is replaced on the next save")
    func corruptFile() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let url = tmp.file("backups.json")
        try Data("{ not json".utf8).write(to: url)
        let service = ConfigurationBackupService(fileURL: url)
        #expect(service.backup(for: Fixtures.asus.key) == nil)
        try service.save(record(Fixtures.asus, modeID: 119))
        #expect(service.backup(for: Fixtures.asus.key)?.mode.modeID == 119)
    }

    @Test("Persistent key uses the display UUID, or vendor-product-serial without one")
    func persistentKey() {
        #expect(Fixtures.asus.identity.persistentKey == Fixtures.asus.uuid)
        let noUUID = DisplayIdentity(vendorID: 1715, productID: 13355, serialNumber: 0, uuid: nil)
        #expect(noUUID.persistentKey == "06b3-342b-0")
        #expect(noUUID.hexDescription == "vendor 0x06B3 · product 0x342B")
    }
}

@MainActor
@Suite("History store", .serialized)
struct HistoryStoreTests {
    private func entry(_ index: Int, kind: HistoryEntry.Kind = .trialStarted) -> HistoryEntry {
        HistoryEntry(
            date: Fixtures.fixedDate.addingTimeInterval(Double(index)), kind: kind, displayName: "VG34WQML5A",
            displayKey: Fixtures.asus.key, from: Fixtures.asus.mode(119).signature,
            to: Fixtures.asus.mode(80).signature, detail: "entry \(index)")
    }

    @Test("Entries are returned newest first")
    func ordering() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let store = HistoryStore(fileURL: tmp.file("history.json"))
        #expect(store.entries().isEmpty)
        for index in 0..<3 { store.append(entry(index)) }
        #expect(store.entries().map(\.detail) == ["entry 2", "entry 1", "entry 0"])
    }

    @Test("The log is capped, dropping the oldest entries")
    func cap() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let url = tmp.file("history.json")
        let store = HistoryStore(fileURL: url, limit: 3)
        for index in 0..<5 { store.append(entry(index)) }
        #expect(store.entries().map(\.detail) == ["entry 4", "entry 3", "entry 2"])
        // The cap is applied on disk, not only when reading.
        let onDisk = try #require(try JSONFileStore<[HistoryEntry]>(url: url).load())
        #expect(onDisk.count == 3)
    }

    @Test("Entries round-trip with their kind and signatures")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let store = HistoryStore(fileURL: tmp.file("history.json"))
        let original = entry(7, kind: .autoReverted)
        store.append(original)
        #expect(store.entries() == [original])
        #expect(original.kind.label == "Automatically reverted")
    }

    @Test("A write failure is logged, not thrown")
    func unwritable() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let store = HistoryStore(fileURL: try tmp.unwritableDirectory().appendingPathComponent("history.json"))
        store.append(entry(0))
        #expect(store.entries().isEmpty)
    }
}

@MainActor
@Suite("Verification store", .serialized)
struct VerificationStoreTests {
    private func record(_ fixture: MonitorFixture, _ modeID: Int32, at offset: TimeInterval = 0) -> VerificationRecord {
        VerificationRecord(
            displayKey: fixture.key, displayName: fixture.name, signature: fixture.mode(modeID).signature,
            verifiedAt: Fixtures.fixedDate.addingTimeInterval(offset), osVersion: "macOS 27.0",
            hardwareModel: "Mac16,10", observedScale: fixture.mode(modeID).scaleFactor, method: "test")
    }

    @Test("Recording the same display and signature again replaces the old record")
    func dedupe() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let store = VerificationStore(fileURL: tmp.file("verifications.json"))
        store.record(record(Fixtures.asus, 80))
        store.record(record(Fixtures.asus, 80, at: 3600))
        #expect(store.records().count == 1)
        #expect(store.records().first?.verifiedAt == Fixtures.fixedDate.addingTimeInterval(3600))
    }

    @Test("Verified signatures are scoped to one display")
    func perDisplay() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let store = VerificationStore(fileURL: tmp.file("verifications.json"))
        store.record(record(Fixtures.asus, 80))
        store.record(record(Fixtures.asus, 119))
        store.record(record(Fixtures.msi, 13))
        #expect(store.records().count == 3)
        #expect(store.verifiedSignatures(for: Fixtures.asus.key) == [Fixtures.asus.mode(80).signature, Fixtures.asus.mode(119).signature])
        #expect(store.verifiedSignatures(for: Fixtures.msi.key) == [Fixtures.msi.mode(13).signature])
        #expect(store.verifiedSignatures(for: "nobody").isEmpty)
    }
}

@Suite("JSON file store", .serialized)
struct JSONFileStoreTests {
    @Test("Missing file loads as nil; save, load and delete round-trip")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let store = JSONFileStore<[String: Int]>(url: tmp.url.appendingPathComponent("nested/dir/value.json"))
        #expect(try store.load() == nil)
        try store.save(["a": 1])
        #expect(try store.load() == ["a": 1])
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete() // deleting a missing file is not an error
    }

    @Test("A corrupt file throws on load")
    func corrupt() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let url = tmp.file("value.json")
        try Data("garbage".utf8).write(to: url)
        #expect(throws: (any Error).self) { try JSONFileStore<[String: Int]>(url: url).load() }
    }

    @Test("App paths are all inside the root")
    func paths() {
        let root = URL(fileURLWithPath: "/tmp/ScaleKitPathsTest", isDirectory: true)
        let paths = AppPaths(root: root)
        for url in [paths.backupFile, paths.historyFile, paths.verificationsFile, paths.trialJournalFile, paths.guardLogFile, paths.reportsDirectory] {
            #expect(url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
        }
        #expect(paths.trialJournalFile.lastPathComponent == "trial.json")
    }
}

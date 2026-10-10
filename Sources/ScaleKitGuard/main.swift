// ScaleKitGuard — an unprivileged watchdog for display-change trials.
//
// ScaleKit applies trial changes with kCGConfigureForAppOnly, which WindowServer
// undoes when ScaleKit exits. That covers crashes and quits but not a hang:
// a frozen app never shows its countdown and never exits. This process watches
// the trial journal and, if the deadline passes while the trial is still
// pending, terminates ScaleKit so that WindowServer restores the display. If
// the display is still not back to the saved mode, it restores the user's
// permanent display configuration.
//
// It runs as the current user, needs no entitlements, and exits as soon as the
// trial is resolved or the parent process exits.

import CoreGraphics
import Foundation
import ScaleKitCore

struct Options {
    var journal: URL
    var parent: Int32
    var trialID: UUID
    var grace: TimeInterval
    var log: URL?

    init?(_ arguments: [String]) {
        var values: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count {
            values[String(arguments[index].drop { $0 == "-" })] = arguments[index + 1]
            index += 2
        }
        guard let journal = values["journal"], let parent = values["parent"].flatMap(Int32.init),
              let trial = values["trial"].flatMap(UUID.init(uuidString:))
        else { return nil }
        self.journal = URL(fileURLWithPath: journal)
        self.parent = parent
        self.trialID = trial
        self.grace = values["grace"].flatMap(TimeInterval.init) ?? 8
        self.log = values["log"].map { URL(fileURLWithPath: $0) }
    }
}

guard let options = Options(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: ScaleKitGuard --journal PATH --parent PID --trial UUID [--grace S] [--log PATH]\n".utf8))
    exit(2)
}

// Leave the parent's process group so a Ctrl-C in a terminal does not stop the guard too.
setsid()
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) [guard \(getpid())] \(message)\n"
    guard let url = options.log else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

let store = JSONFileStore<TrialJournal>(url: options.journal)

@MainActor
func restoreIfNeeded(_ journal: TrialJournal) -> String {
    let hardware = LiveDisplayHardware()
    let services = ScaleKitServices(hardware: hardware, guardLauncher: nil)
    guard let display = services.discovery.discover().first(where: { $0.key == journal.displayKey }) else {
        return "display not connected"
    }
    // The monitor can take a moment to settle after ScaleKit exits.
    for _ in 0..<6 {
        if hardware.currentMode(for: display.id)?.signature == journal.previous.signature {
            return "previous mode active (\(journal.previous.summary))"
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    // While a ScaleKit virtual display still exists, the "permanent"
    // configuration can be a mirror set saved for it; restoring that would
    // not help. It disappears with its process.
    if hardware.onlineDisplayIDs().contains(where: { CGDisplayVendorNumber($0) == 0x534B }) {
        return "a ScaleKit virtual display is still online; not restoring the permanent configuration"
    }
    hardware.restorePermanentConfiguration()
    Thread.sleep(forTimeInterval: 1.5)
    let now = hardware.currentMode(for: display.id)
    return now?.signature == journal.previous.signature
        ? "restored permanent configuration (\(journal.previous.summary))"
        : "restore attempted; active mode is \(now?.summary ?? "unknown")"
}

@MainActor
func finish(_ state: TrialJournal.State, note: String) -> Never {
    if var journal = try? store.load(), journal.trialID == options.trialID, journal.state == .pending {
        journal.state = state
        journal.note = note
        journal.updatedAt = Date()
        try? store.save(journal)
    }
    log(note)
    exit(0)
}

log("watching trial \(options.trialID) for pid \(options.parent)")

MainActor.assumeIsolated {
    while true {
        guard let journal = try? store.load(), journal.trialID == options.trialID else {
            log("journal replaced or missing; exiting")
            exit(0)
        }
        guard journal.state == .pending else {
            log("trial resolved by ScaleKit (\(journal.state.rawValue)); exiting")
            exit(0)
        }
        if !isProcessAlive(options.parent) {
            Thread.sleep(forTimeInterval: 1.0)
            let result = restoreIfNeeded(journal)
            finish(.revertedBySystem, note: "ScaleKit exited before confirmation; \(result)")
        }
        if Date() > journal.deadline.addingTimeInterval(options.grace) {
            log("deadline passed while trial still pending; ScaleKit appears unresponsive — sending SIGTERM")
            kill(options.parent, SIGTERM)
            for _ in 0..<20 where isProcessAlive(options.parent) {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if isProcessAlive(options.parent) {
                log("still running — sending SIGKILL")
                kill(options.parent, SIGKILL)
                Thread.sleep(forTimeInterval: 0.5)
            }
            Thread.sleep(forTimeInterval: 1.0)
            let result = restoreIfNeeded(journal)
            finish(.revertedByGuard, note: "Watchdog ended an unresponsive ScaleKit; \(result)")
        }
        // Never outlive the trial by more than a minute, even if nothing else ends it.
        if Date() > journal.deadline.addingTimeInterval(options.grace + 60) {
            log("hard stop reached; exiting")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

import AppKit
import CoreGraphics

/// Decoded `CGDisplayChangeSummaryFlags`.
public struct DisplayChangeSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let beginConfiguration = DisplayChangeSet(rawValue: 1 << 0)
    public static let moved = DisplayChangeSet(rawValue: 1 << 1)
    public static let setMain = DisplayChangeSet(rawValue: 1 << 2)
    public static let setMode = DisplayChangeSet(rawValue: 1 << 3)
    public static let added = DisplayChangeSet(rawValue: 1 << 4)
    public static let removed = DisplayChangeSet(rawValue: 1 << 5)
    public static let enabled = DisplayChangeSet(rawValue: 1 << 8)
    public static let disabled = DisplayChangeSet(rawValue: 1 << 9)
    public static let mirror = DisplayChangeSet(rawValue: 1 << 10)
    public static let unmirror = DisplayChangeSet(rawValue: 1 << 11)
    public static let desktopShapeChanged = DisplayChangeSet(rawValue: 1 << 12)

    private static let named: [(DisplayChangeSet, String)] = [
        (.beginConfiguration, "begin"), (.moved, "moved"), (.setMain, "setMain"), (.setMode, "setMode"),
        (.added, "added"), (.removed, "removed"), (.enabled, "enabled"), (.disabled, "disabled"),
        (.mirror, "mirror"), (.unmirror, "unmirror"), (.desktopShapeChanged, "desktopShapeChanged"),
    ]

    public var names: [String] { Self.named.filter { contains($0.0) }.map(\.1) }

    /// The "before" notification carries no state; only the "after" one is useful.
    public var isPreflight: Bool { contains(.beginConfiguration) }
}

public enum DisplayEvent: Sendable, Equatable {
    case reconfigured(displayID: UInt32, changes: DisplayChangeSet)
    case screenParametersChanged
    case systemWillSleep
    case systemDidWake
    case screensDidSleep
    case screensDidWake
    case systemWillPowerOff

    public var description: String {
        switch self {
        case .reconfigured(let id, let changes): "Display \(id): \(changes.names.joined(separator: ", "))"
        case .screenParametersChanged: "Screen parameters changed"
        case .systemWillSleep: "System will sleep"
        case .systemDidWake: "System did wake"
        case .screensDidSleep: "Screens did sleep"
        case .screensDidWake: "Screens did wake"
        case .systemWillPowerOff: "System will power off"
        }
    }
}

public struct RecordedDisplayEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var description: String

    public init(id: UUID = UUID(), date: Date, description: String) {
        self.id = id
        self.date = date
        self.description = description
    }
}

/// Watches for display connection, mode, sleep and wake events.
///
/// Sources: `CGDisplayRegisterReconfigurationCallback`, NSWorkspace sleep and
/// wake notifications, and `NSApplication.didChangeScreenParametersNotification`.
/// Handlers run on the main actor.
@MainActor
public final class DisplayEventMonitor {
    public typealias Handler = @MainActor (DisplayEvent) -> Void

    private var handlers: [UUID: Handler] = [:]
    private var observers: [NSObjectProtocol] = []
    private var isRunning = false
    public private(set) var recentEvents: [RecordedDisplayEvent] = []
    public var recentEventLimit = 100

    public init() {}

    @discardableResult
    public func addHandler(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func removeHandler(_ id: UUID) {
        handlers[id] = nil
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let error = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        if error != .success {
            Log.events.error("CGDisplayRegisterReconfigurationCallback failed: \(error.rawValue)")
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let mapping: [(NSNotification.Name, DisplayEvent)] = [
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (NSWorkspace.willPowerOffNotification, .systemWillPowerOff),
        ]
        for (name, event) in mapping {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit(event) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.screenParametersChanged) }
        })
        Log.events.info("Display event monitoring started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Delivers an event to every handler. Public so tests and tools can inject events.
    public func emit(_ event: DisplayEvent) {
        recentEvents.append(RecordedDisplayEvent(date: Date(), description: event.description))
        if recentEvents.count > recentEventLimit {
            recentEvents.removeFirst(recentEvents.count - recentEventLimit)
        }
        Log.events.info("\(event.description, privacy: .public)")
        for handler in handlers.values { handler(event) }
    }

    private static let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let monitor = Unmanaged<DisplayEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let event = DisplayEvent.reconfigured(displayID: displayID, changes: DisplayChangeSet(rawValue: flags.rawValue))
        if Thread.isMainThread {
            MainActor.assumeIsolated { monitor.emit(event) }
        } else {
            Task { @MainActor in monitor.emit(event) }
        }
    }
}

import Foundation

/// How a reported value was obtained.
///
/// Diagnostics must never present an inferred or missing value as if the
/// operating system had reported it directly.
public enum Provenance: String, Codable, Sendable, CaseIterable {
    /// Read directly from a public system API for the current state.
    case measured
    /// Derived from measured values, or read from an undocumented source.
    case inferred
    /// The system does not expose this information.
    case unavailable

    public var label: String {
        switch self {
        case .measured: "Measured"
        case .inferred: "Inferred"
        case .unavailable: "Unavailable"
        }
    }
}

/// A value paired with where it came from.
public struct Fact<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var value: Value?
    public var provenance: Provenance
    /// The API for measured values, the reasoning for inferred values, or why
    /// the value is unavailable.
    public var source: String

    public init(value: Value?, provenance: Provenance, source: String) {
        self.value = value
        self.provenance = value == nil ? .unavailable : provenance
        self.source = source
    }

    public static func measured(_ value: Value, source: String) -> Fact {
        Fact(value: value, provenance: .measured, source: source)
    }

    public static func inferred(_ value: Value, reason: String) -> Fact {
        Fact(value: value, provenance: .inferred, source: reason)
    }

    public static func unavailable(_ reason: String) -> Fact {
        Fact(value: nil, provenance: .unavailable, source: reason)
    }

    public func map<T>(_ transform: (Value) -> T) -> Fact<T> {
        Fact<T>(value: value.map(transform), provenance: provenance, source: source)
    }
}

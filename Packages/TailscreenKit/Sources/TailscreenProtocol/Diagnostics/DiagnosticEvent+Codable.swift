import Foundation

// JSON shape of one event line. Hand-written rather than synthesized because
// the wire format here is a *reading* format — the key names, the number
// formats and the tolerance rules are the interface to whoever opens the file,
// and none of them should change because a Swift property was renamed.
//
// One line looks like:
//
//     {"at":"2026-09-17T10:04:02.117Z","category":"handshake","elapsed_ms":1841.2,
//      "event":"hello.ack.sent","fields":{"addr":"100.64.0.3","caps":"nack|rr|fec","ssrc":2},
//      "role":"sharer","seq":42,"session":0,"severity":"info"}
//
// (`sortedKeys` puts them in alphabetical order, which is why `at` leads.)

extension DiagnosticEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case seq
        case session
        case elapsedMs = "elapsed_ms"
        case at
        case role
        case category
        case event
        case severity
        case fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        // Always written, even for a single-session bundle, so a reader can filter on it.
        try container.encode(session, forKey: .session)
        // Milliseconds with one decimal, not raw nanoseconds — legible at a
        // glance, like `InputDebugLog.ms`. `seq` still orders exactly within a side.
        let ms = (Double(monotonicNs) / 1_000_000).rounded(toPlaces: 1)
        try container.encode(ms, forKey: .elapsedMs)
        try container.encode(wallClock, forKey: .at)
        try container.encode(role, forKey: .role)
        try container.encode(category, forKey: .category)
        try container.encode(name, forKey: .event)
        try container.encode(severity, forKey: .severity)
        // Omitted when empty, not written as `{}` — most events carry no fields.
        if !fields.isEmpty {
            try container.encode(fields, forKey: .fields)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        // Absent in bundles written before sessions were stamped — reads
        // correctly as the one session they describe.
        session = try container.decodeIfPresent(UInt32.self, forKey: .session) ?? 0
        // Clamped, not converted directly — `UInt64(someDouble)` traps on
        // NaN/infinity/overflow, and a hostile `"elapsed_ms":1e300` must not
        // crash the reader.
        let ms = try container.decodeIfPresent(Double.self, forKey: .elapsedMs) ?? 0
        monotonicNs = DiagnosticEvent.nanoseconds(fromMilliseconds: ms)
        wallClock = try container.decode(Date.self, forKey: .at)
        // Unknown roles/categories/severities fall back rather than throwing,
        // so a newer build's bundle stays readable.
        role =
            (try? container.decode(DiagnosticRole.self, forKey: .role)) ?? .app
        category =
            (try? container.decode(DiagnosticCategory.self, forKey: .category)) ?? .fault
        name = try container.decode(String.self, forKey: .event)
        severity =
            (try? container.decode(DiagnosticSeverity.self, forKey: .severity)) ?? .info
        fields =
            (try? container.decode([String: DiagnosticValue].self, forKey: .fields)) ?? [:]
    }
}

extension DiagnosticValue: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: `Bool` first (JSON `true` could otherwise decode as
        // 1), `Int64` before `Double` so whole numbers survive as such.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

extension DiagnosticEvent {
    /// Milliseconds → nanoseconds, saturating instead of trapping. Not
    /// finite or not positive becomes 0 (garbage deserves an honest 0, not
    /// `.max`, which would falsely sort it last); a genuinely too-large
    /// finite value saturates to `.max`.
    static func nanoseconds(fromMilliseconds ms: Double) -> UInt64 {
        guard ms.isFinite, ms > 0 else { return 0 }
        let ns = ms * 1_000_000
        guard ns < Double(UInt64.max) else { return .max }
        return UInt64(ns)
    }
}

extension Double {
    /// Round for display. Keeps the encoded number short instead of letting
    /// binary floating point write `1841.2000000000001` into a file a person
    /// is going to read.
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

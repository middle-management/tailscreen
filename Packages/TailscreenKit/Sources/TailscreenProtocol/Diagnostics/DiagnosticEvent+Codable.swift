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
//      "role":"sharer","seq":42,"severity":"info"}
//
// (`sortedKeys` puts them in alphabetical order, which is why `at` leads.)

extension DiagnosticEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case seq
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
        // Milliseconds with one decimal, not raw nanoseconds. This is the
        // column a reader's eye actually runs down — "how long after the start
        // did this happen" — and 1841.2 answers it at a glance where
        // 1841203847 does not. The same choice `InputDebugLog.ms` makes, for
        // the same reason. Full precision is not lost that matters: ordering
        // within a side is `seq`, which is exact.
        let ms = (Double(monotonicNs) / 1_000_000).rounded(toPlaces: 1)
        try container.encode(ms, forKey: .elapsedMs)
        try container.encode(wallClock, forKey: .at)
        try container.encode(role, forKey: .role)
        try container.encode(category, forKey: .category)
        try container.encode(name, forKey: .event)
        try container.encode(severity, forKey: .severity)
        // Omitted when empty rather than written as `{}` — most events carry
        // no fields and the noise is the majority of the file otherwise.
        if !fields.isEmpty {
            try container.encode(fields, forKey: .fields)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        let ms = try container.decodeIfPresent(Double.self, forKey: .elapsedMs) ?? 0
        monotonicNs = ms > 0 ? UInt64(ms * 1_000_000) : 0
        wallClock = try container.decode(Date.self, forKey: .at)
        // Unknown roles, categories and severities fall back rather than
        // throwing: a bundle from a newer build must stay readable, and an
        // event whose category this build has never heard of is still an event
        // worth showing. Same tolerance rule as the wire's HELLO_ACK decode.
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
        // Order matters: `Bool` first because JSON `true` would otherwise
        // decode as the integer 1 on some platforms, and `Int64` before
        // `Double` so a whole number survives as a whole number rather than
        // coming back as `42.0`.
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

extension Double {
    /// Round for display. Keeps the encoded number short instead of letting
    /// binary floating point write `1841.2000000000001` into a file a person
    /// is going to read.
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

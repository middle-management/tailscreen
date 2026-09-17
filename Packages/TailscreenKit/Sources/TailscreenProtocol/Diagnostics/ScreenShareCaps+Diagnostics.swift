import Foundation

extension ScreenShareCaps {
    /// The negotiated capabilities as a stable, readable field value:
    /// `"nack|rr|fec"`, or `"none"` for a legacy capability-less peer.
    ///
    /// Spelled out rather than recorded as the raw bitmask because the
    /// capability set is the single most-consulted fact in a handshake
    /// investigation — "was FEC on?", "why is Request Control hidden?" — and
    /// `7` requires a reader to have the bit table in front of them while
    /// `nack|rr|fec` does not. The short spellings are deliberate and stable:
    /// they are part of the bundle format, so treat them like the names in
    /// ``DiagnosticEventName`` and do not re-word them.
    ///
    /// Sorted by bit position, so the same set always renders the same string
    /// and two bundles compare as text.
    public var diagnosticDescription: String {
        var parts: [String] = []
        if contains(.nack) { parts.append("nack") }
        if contains(.receiverReport) { parts.append("rr") }
        if contains(.fec) { parts.append("fec") }
        if contains(.remoteControl) { parts.append("control") }
        if contains(.annotations) { parts.append("annotations") }
        if contains(.tenBit) { parts.append("10bit") }

        // Bits this build has never heard of are reported rather than dropped:
        // a peer advertising something newer is exactly the case where a
        // reader needs to know the set was not fully understood.
        let known: ScreenShareCaps = [
            .nack, .receiverReport, .fec, .remoteControl, .annotations, .tenBit
        ]
        let unknown = rawValue & ~known.rawValue
        if unknown != 0 {
            parts.append(String(format: "unknown:0x%02x", unknown))
        }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }
}

import Foundation

extension ScreenShareCaps {
    /// The negotiated capabilities as a stable, readable field value:
    /// `"nack|rr|fec"`, or `"none"` for a legacy capability-less peer.
    ///
    /// These short spellings are part of the bundle format, like
    /// ``DiagnosticEventName`` — do not re-word them. Sorted by bit position
    /// so the same set always renders the same string.
    public var diagnosticDescription: String {
        var parts: [String] = []
        if contains(.nack) { parts.append("nack") }
        if contains(.receiverReport) { parts.append("rr") }
        if contains(.fec) { parts.append("fec") }
        if contains(.remoteControl) { parts.append("control") }
        if contains(.annotations) { parts.append("annotations") }
        if contains(.tenBit) { parts.append("10bit") }

        // Report unknown bits rather than drop them: a peer advertising
        // something newer than this build needs to be visible, not silent.
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

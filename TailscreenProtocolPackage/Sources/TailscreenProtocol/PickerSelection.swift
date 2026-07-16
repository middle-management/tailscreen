import Foundation

/// What the user picked in `SCContentSharingPicker`, distilled down to
/// primitives so it can cross a process boundary. Encoded as JSON for
/// the picker-helper → main → capture-helper hop because
/// `SCContentFilter` doesn't conform to `NSCoding` — there's no
/// archive-and-replay path for the live class instance, so we ship
/// IDs instead and rebuild the filter inside the capture-helper.
public struct PickerSelection: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case display
        case window
        case application
    }

    public let kind: Kind
    /// For `.display`: the picked display. For `.application`: the
    /// display the picker chose to host the app share against.
    public let displayID: UInt32?
    /// For `.window`: the chosen window's `CGWindowID`.
    public let windowID: UInt32?
    /// For `.application`: bundle IDs of the apps to share. One entry
    /// for single-app, multiple for multi-app.
    public let bundleIDs: [String]
    /// Whether the capture-helper should also configure system-audio capture
    /// (an `.audio` SCStream output). Non-optional with a custom decoder that
    /// defaults a *missing* key to `false`, so JSON produced by an older
    /// picker-helper (which never wrote the field) still decodes. Emission is
    /// separately gated by the `setAudioEnabled` latch, so this only controls
    /// whether the output exists.
    public let captureAudio: Bool

    public init(
        kind: Kind,
        displayID: UInt32?,
        windowID: UInt32?,
        bundleIDs: [String],
        captureAudio: Bool = false
    ) {
        self.kind = kind
        self.displayID = displayID
        self.windowID = windowID
        self.bundleIDs = bundleIDs
        self.captureAudio = captureAudio
    }

    private enum CodingKeys: String, CodingKey {
        case kind, displayID, windowID, bundleIDs, captureAudio
    }

    /// Custom decode so a missing `captureAudio` key (old picker-helper JSON)
    /// falls back to `false` instead of failing. `encode(to:)` stays
    /// synthesized — the field always serializes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID)
        windowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID)
        bundleIDs = try container.decode([String].self, forKey: .bundleIDs)
        captureAudio = try container.decodeIfPresent(Bool.self, forKey: .captureAudio) ?? false
    }

    /// A copy with `captureAudio` set — used by the sharer to turn on the
    /// helper's audio output without mutating the picker-produced value.
    public func settingCaptureAudio(_ on: Bool) -> PickerSelection {
        PickerSelection(
            kind: kind, displayID: displayID, windowID: windowID,
            bundleIDs: bundleIDs, captureAudio: on)
    }
}

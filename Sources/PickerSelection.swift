import Foundation

/// What the user picked in `SCContentSharingPicker`, distilled down to
/// primitives so it can cross a process boundary. Encoded as JSON for
/// the picker-helper → main → capture-helper hop because
/// `SCContentFilter` doesn't conform to `NSCoding` — there's no
/// archive-and-replay path for the live class instance, so we ship
/// IDs instead and rebuild the filter inside the capture-helper.
struct PickerSelection: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case display
        case window
        case application
    }

    let kind: Kind
    /// For `.display`: the picked display. For `.application`: the
    /// display the picker chose to host the app share against.
    let displayID: UInt32?
    /// For `.window`: the chosen window's `CGWindowID`.
    let windowID: UInt32?
    /// For `.application`: bundle IDs of the apps to share. One entry
    /// for single-app, multiple for multi-app.
    let bundleIDs: [String]
}

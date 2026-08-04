import Foundation

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Resolve a user-facing string from Tailscreen's shared localization catalog.
///
/// One function, one catalog, three apps: the macOS app, the GTK app and the
/// WinUI app all call this, and all three read the same
/// `<lang>.lproj/Localizable.strings` shipped by this package.
///
/// The key is the English source text itself (Apple's recommended
/// base-language-as-key convention), so a missing catalog, a missing
/// translation, or a missing *key* within a translation all degrade to
/// perfectly good English rather than to a placeholder. That property is load
/// bearing — it is why a packaging mistake that leaves the resource bundle
/// behind produces an untranslated app rather than a broken one.
///
/// String interpolation is supported and produces the usual format specifiers
/// in the key: `L("Viewing \(host)")` looks up `"Viewing %@"`, and
/// `L("\(count) viewers")` looks up `"%lld viewers"`. Adding a language is
/// dropping a translated `Localizable.strings` into a new `<lang>.lproj` under
/// `Sources/TailscreenL10n/Resources/` — no code changes.
///
/// Use `L(_:)` for plain `String` call sites (AppKit titles, `.help`,
/// notification text, swift-cross-ui's `Button`/`Text`) and wrap SwiftUI
/// `Text` as `Text(L("…"))`. Log lines (`TSLogger` / `print`) are
/// intentionally left untranslated.
///
/// The name `L` is a deliberate, widely-used shorthand for the localization
/// lookup (it mirrors the conventional `NSLocalizedString` wrapper name); the
/// `AlwaysUseLowerCamelCase` rule is waived for it via the
/// `swift-format-ignore` directive above.
public func L(_ key: LocalizationKey) -> String {
    LocalizationCatalog.shared.string(for: key)
}

/// A catalog key: the English source text, plus whatever was interpolated into
/// it.
///
/// This exists because `String.LocalizationValue` — what the macOS app used
/// before the catalog was shared — is Apple Foundation, and the interpolation
/// half of it is the part that cannot be replaced by a plain `String`
/// parameter: `L("Viewing \(host)")` has to become the key `"Viewing %@"` plus
/// the argument `host`, and by the time an interpolated `String` reaches a
/// function the two are already fused.
///
/// The specifiers produced here match what `String.LocalizationValue` produced
/// for the same call sites (`%@` for text, `%lld` for `Int`), which is why the
/// existing catalog needed no rewriting when the mac app moved onto this type.
public struct LocalizationKey: ExpressibleByStringInterpolation, Sendable {
    /// The lookup key: source text with interpolations replaced by printf-style
    /// specifiers.
    public let format: String
    /// The interpolated values, in source order.
    let arguments: [Argument]

    /// The two argument kinds the catalog actually contains. Deliberately not
    /// `CVarArg`: that protocol is neither `Sendable` nor uniformly available
    /// off Darwin, and the rendering here is a plain `String(describing:)`
    /// either way.
    enum Argument: Sendable {
        case text(String)
        case integer(Int)
    }

    public init(stringLiteral value: String) {
        self.format = value
        self.arguments = []
    }

    public init(stringInterpolation: Interpolation) {
        self.format = stringInterpolation.format
        self.arguments = stringInterpolation.arguments
    }

    init(format: String, arguments: [Argument]) {
        self.format = format
        self.arguments = arguments
    }

    public struct Interpolation: StringInterpolationProtocol, Sendable {
        var format = ""
        var arguments: [Argument] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            format.reserveCapacity(literalCapacity + interpolationCount * 4)
            arguments.reserveCapacity(interpolationCount)
        }

        /// Literal segments are appended verbatim — a `%` in the source text
        /// is NOT escaped to `%%`.
        ///
        /// That is a copy of what `String.LocalizationValue` did, and it has
        /// to be, because the existing catalog was written against it: the key
        /// for the zoom menu item really is `"Zoom to 50%"` with a bare
        /// trailing percent. `LocalizationFormat` is the half that absorbs the
        /// consequence — it copies through any `%` that does not introduce a
        /// specifier it recognizes.
        public mutating func appendLiteral(_ literal: String) {
            format += literal
        }

        public mutating func appendInterpolation(_ value: String) {
            format += "%@"
            arguments.append(.text(value))
        }

        public mutating func appendInterpolation(_ value: Int) {
            format += "%lld"
            arguments.append(.integer(value))
        }

        /// Everything else — including a bare `any Error`, which several call
        /// sites interpolate and which conforms to nothing useful. Deliberately
        /// unconstrained rather than `CustomStringConvertible`: a constraint
        /// here buys nothing (the rendering is `String(describing:)` either
        /// way) and turns "this value has no description" into a compile error
        /// at a call site that only wanted to name a failure.
        ///
        /// The two concrete overloads above still win for `String` and `Int` —
        /// Swift prefers a non-generic overload — which is what keeps `%lld`
        /// on the keys that already had it.
        public mutating func appendInterpolation<T>(_ value: T) {
            format += "%@"
            arguments.append(.text(String(describing: value)))
        }
    }
}

import Foundation

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Resolve a user-facing string from Tailscreen's shared localization catalog.
/// Called by all three apps against the same `<lang>.lproj/Localizable
/// .strings`; see `.claude/rules/localization.md` for call-site conventions.
///
/// Key = English source text (base-language-as-key), so a missing catalog,
/// translation or key all degrade to plain English rather than a placeholder
/// — this is why a packaging mistake produces an untranslated app, not a
/// broken one. Interpolation produces printf specifiers in the key:
/// `L("Viewing \(host)")` looks up `"Viewing %@"`.
public func L(_ key: LocalizationKey) -> String {
    LocalizationCatalog.shared.string(for: key)
}

/// A catalog key: the English source text, plus whatever was interpolated
/// into it. Replaces `String.LocalizationValue` (Apple Foundation-only);
/// produces the same specifiers (`%@` text, `%lld` Int) so the existing
/// catalog needed no rewriting.
public struct LocalizationKey: ExpressibleByStringInterpolation, Sendable {
    /// The lookup key: source text with interpolations replaced by printf-style
    /// specifiers.
    public let format: String
    /// The interpolated values, in source order.
    let arguments: [Argument]

    /// Deliberately not `CVarArg`: not `Sendable`, not uniformly available off
    /// Darwin, and rendering here is plain `String(describing:)` anyway.
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

        /// Literal segments are appended verbatim — a `%` in source text is
        /// NOT escaped to `%%` (the catalog has real keys like `"Zoom to
        /// 50%"`). `LocalizationFormat` copies through any `%` it doesn't
        /// recognize as a specifier.
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

        /// Fallback for everything else (e.g. `any Error`). Deliberately
        /// unconstrained rather than `CustomStringConvertible` — rendering is
        /// `String(describing:)` either way. The concrete `String`/`Int`
        /// overloads above still win (Swift prefers non-generic overloads).
        public mutating func appendInterpolation<T>(_ value: T) {
            format += "%@"
            arguments.append(.text(String(describing: value)))
        }
    }
}

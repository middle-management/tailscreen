import Foundation

/// Substitutes a key's interpolated arguments into a (possibly translated)
/// format string.
///
/// Written by hand rather than deferring to `String(format:)` for two reasons,
/// both of which are about the translated side rather than the English one:
///
/// 1. **Reordering has to work.** A translation is free to move `%@` before
///    `%lld` and say so with the positional forms (`%1$@`, `%2$lld`) — for
///    several languages that is the only way to write a grammatical sentence.
///    `String(format:)` supports positional specifiers on Darwin; on
///    swift-corelibs-foundation that support is thinner, and a formatter that
///    silently produces a different sentence on Linux is exactly the failure
///    this package exists to avoid.
/// 2. **A wrong translation must not be fatal.** `String(format:)` reads its
///    arguments through a varargs list typed by the format string, so a
///    translator who types `%d` where the key says `%@` gets a garbage pointer
///    read. Here the argument list is the authority and the conversion
///    character only says *which* argument to take, so the worst outcome is an
///    oddly rendered word.
enum LocalizationFormat {
    /// Render `format`, replacing recognized specifiers with `arguments`.
    ///
    /// Anything unrecognized — a bare `%` at the end of "Zoom to 50%", a
    /// specifier past the end of the argument list — is copied through
    /// literally. With no arguments the format is returned unchanged, which is
    /// both the fast path and what keeps percent-bearing non-interpolated keys
    /// exactly as their author wrote them.
    static func render(_ format: String, _ arguments: [LocalizationKey.Argument]) -> String {
        guard !arguments.isEmpty else { return format }

        var out = ""
        out.reserveCapacity(format.count)
        let chars = Array(format)
        var index = 0
        var nextArgument = 0

        while index < chars.count {
            guard chars[index] == "%" else {
                out.append(chars[index])
                index += 1
                continue
            }
            guard let specifier = parseSpecifier(chars, at: index) else {
                // Not a specifier we understand — a literal percent.
                out.append("%")
                index += 1
                continue
            }
            if specifier.isEscapedPercent {
                out.append("%")
                index = specifier.end
                continue
            }
            // Positional specifiers are 1-based; unpositioned ones consume the
            // argument list in order. A format that mixes the two — which a
            // half-updated translation can produce — is resolved by letting
            // each unpositioned specifier take the next unconsumed slot.
            let argumentIndex: Int
            if let position = specifier.position {
                argumentIndex = position - 1
            } else {
                argumentIndex = nextArgument
                nextArgument += 1
            }
            guard argumentIndex >= 0, argumentIndex < arguments.count else {
                // More specifiers than arguments: emit the specifier verbatim
                // so the mismatch is visible to whoever reads the screenshot,
                // rather than silently dropping a word.
                out.append(contentsOf: chars[index..<specifier.end])
                index = specifier.end
                continue
            }
            out += render(arguments[argumentIndex])
            index = specifier.end
        }
        return out
    }

    /// Stand-in every specifier collapses to under `normalizeSpecifiers`. NUL
    /// cannot occur in a real key, so it never collides with source text.
    static let specifierPlaceholder = "\u{0}ARG"

    /// Replace every specifier with `specifierPlaceholder`, leaving literal
    /// text (including a bare `%`) alone.
    ///
    /// Two callers depend on this being one function. The catalog test matches
    /// call-site keys against catalog keys through it, because a call site
    /// writes `\(host)` where the catalog writes `%@`. The runtime uses it as a
    /// SECOND lookup index, so a key whose specifier disagrees with the
    /// catalog's — `%@` against a `%lld`, or a translator's `%d` against a
    /// `%lld` — still finds its translation instead of silently falling back
    /// to English. Rendering never reads the conversion character anyway: the
    /// argument list already knows what each slot holds.
    static func normalizeSpecifiers(_ format: String) -> String {
        var out = ""
        out.reserveCapacity(format.count)
        let chars = Array(format)
        var index = 0
        while index < chars.count {
            guard chars[index] == "%", let specifier = parseSpecifier(chars, at: index) else {
                out.append(chars[index])
                index += 1
                continue
            }
            out += specifier.isEscapedPercent ? "%" : specifierPlaceholder
            index = specifier.end
        }
        return out
    }

    private static func render(_ argument: LocalizationKey.Argument) -> String {
        switch argument {
        case .text(let value): return value
        case .integer(let value): return String(value)
        }
    }

    private struct Specifier {
        /// Index just past the specifier.
        var end: Int
        /// 1-based argument position from a `%n$…` form, if present.
        var position: Int?
        /// `%%`.
        var isEscapedPercent = false
    }

    /// Parse `%[n$][length]conversion` starting at `start` (which must be `%`).
    ///
    /// Length modifiers (`l`, `ll`, `z`, `h`, `hh`, `q`) are accepted and
    /// ignored: the argument list already knows whether a slot is text or an
    /// integer, so `%lld` and `%d` are the same instruction here. Returns nil
    /// when the sequence is not a specifier at all.
    private static func parseSpecifier(_ chars: [Character], at start: Int) -> Specifier? {
        var index = start + 1
        guard index < chars.count else { return nil }

        if chars[index] == "%" {
            return Specifier(end: index + 1, position: nil, isEscapedPercent: true)
        }

        var position: Int?
        var digits = ""
        var scan = index
        while scan < chars.count, chars[scan].isNumber {
            digits.append(chars[scan])
            scan += 1
        }
        if !digits.isEmpty, scan < chars.count, chars[scan] == "$", let parsed = Int(digits) {
            position = parsed
            index = scan + 1
        }

        while index < chars.count, "lzhq".contains(chars[index]) {
            index += 1
        }
        guard index < chars.count, "@diufgsSxX".contains(chars[index]) else { return nil }
        return Specifier(end: index + 1, position: position)
    }
}

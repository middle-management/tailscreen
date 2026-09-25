import Foundation

/// Substitutes a key's interpolated arguments into a (possibly translated)
/// format string.
///
/// Written by hand rather than using `String(format:)`: (1) positional
/// specifiers (`%1$@`, `%2$lld`), which some translations need for
/// grammatical word order, are thinly supported on swift-corelibs-foundation;
/// (2) `String(format:)` reads varargs typed by the format string, so a
/// translator's `%d` where the key says `%@` is a garbage pointer read — here
/// the argument list is the authority, so the worst case is a misrendered word.
enum LocalizationFormat {
    /// Render `format`, replacing recognized specifiers with `arguments`.
    /// Anything unrecognized (a bare `%`, a specifier past the argument list)
    /// is copied through literally.
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
            // list in order (handles a half-updated translation mixing both).
            let argumentIndex: Int
            if let position = specifier.position {
                argumentIndex = position - 1
            } else {
                argumentIndex = nextArgument
                nextArgument += 1
            }
            guard argumentIndex >= 0, argumentIndex < arguments.count else {
                // More specifiers than arguments: emit verbatim so the
                // mismatch is visible rather than silently dropping a word.
                out.append(contentsOf: chars[index..<specifier.end])
                index = specifier.end
                continue
            }
            out += render(arguments[argumentIndex])
            index = specifier.end
        }
        return out
    }

    /// Stand-in every specifier collapses to. NUL cannot occur in a real key.
    static let specifierPlaceholder = "\u{0}ARG"

    /// Replace every specifier with `specifierPlaceholder`, leaving literal
    /// text alone. Used both by the catalog test (matching `\(host)` against
    /// `%@`) and as a second runtime lookup index, so a specifier mismatch
    /// (`%@` vs `%lld`) still finds its translation instead of falling back
    /// to English.
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

    /// Parse `%[n$][length]conversion` starting at `start` (must be `%`).
    /// Length modifiers are accepted and ignored — `%lld` and `%d` are the
    /// same instruction here. Returns nil if not a specifier.
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

import Foundation

/// Parser for Apple's `.strings` catalog format.
///
/// The format is `"key" = "value";` entries separated by whitespace, with `//`
/// and `/* … */` comments (which is where translator notes live, and where
/// this catalog keeps its section MARKs). Parsed here rather than through
/// `PropertyListSerialization` because the old-style plist reader that would
/// handle it is a Darwin-quality path on Darwin and a much thinner one on
/// swift-corelibs-foundation, and because this parser can be pointed at the
/// checked-in `.strings` files by a test running anywhere.
///
/// Malformed input is not an error worth propagating — a catalog is a
/// translator deliverable, and one bad line should cost one string, not the
/// language. Parsing therefore recovers: it skips to the next `;` and keeps
/// going, so everything the file got right still reaches the screen.
enum StringsFile {
    /// Byte prefix of a binary property list. Xcode rewrites `.strings` files
    /// into binary plists when it processes them; SwiftPM copies them as
    /// written. Both shapes are read here so the catalog survives whichever
    /// build system touched it.
    private static let binaryPlistMagic = Array("bplist00".utf8)

    static func parse(data: Data) -> [String: String] {
        if data.starts(with: binaryPlistMagic) {
            let decoded = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
            return decoded as? [String: String] ?? [:]
        }
        // UTF-16 with a BOM is legal in this format and is what older
        // translation tools emit; UTF-8 is what this repo writes.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        return parse(text: text)
    }

    static func parse(text: String) -> [String: String] {
        var table: [String: String] = [:]
        let chars = Array(text)
        var index = 0

        while index < chars.count {
            skipInsignificant(chars, &index)
            guard index < chars.count else { break }
            guard chars[index] == "\"", let key = scanQuoted(chars, &index) else {
                skipToNextEntry(chars, &index)
                continue
            }
            skipInsignificant(chars, &index)
            guard index < chars.count, chars[index] == "=" else {
                skipToNextEntry(chars, &index)
                continue
            }
            index += 1
            skipInsignificant(chars, &index)
            guard index < chars.count, chars[index] == "\"", let value = scanQuoted(chars, &index)
            else {
                skipToNextEntry(chars, &index)
                continue
            }
            table[key] = value
            skipToNextEntry(chars, &index)
        }
        return table
    }

    /// Advance past whitespace and comments.
    private static func skipInsignificant(_ chars: [Character], _ index: inout Int) {
        while index < chars.count {
            if chars[index].isWhitespace {
                index += 1
            } else if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, chars.count)
            } else {
                return
            }
        }
    }

    /// Advance past the terminating `;` of the current entry — also the
    /// recovery step after a malformed one.
    private static func skipToNextEntry(_ chars: [Character], _ index: inout Int) {
        while index < chars.count, chars[index] != ";" { index += 1 }
        if index < chars.count { index += 1 }
    }

    /// Scan a double-quoted literal starting at `index`, resolving the escapes
    /// this format shares with Swift string literals.
    private static func scanQuoted(_ chars: [Character], _ index: inout Int) -> String? {
        guard index < chars.count, chars[index] == "\"" else { return nil }
        var scan = index + 1
        var out = ""
        while scan < chars.count {
            let character = chars[scan]
            if character == "\"" {
                index = scan + 1
                return out
            }
            guard character == "\\" else {
                out.append(character)
                scan += 1
                continue
            }
            scan += 1
            guard scan < chars.count else { break }
            switch chars[scan] {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "u", "U":
                // \Uxxxx — four hex digits, as emitted by translation tools
                // that escape non-ASCII. Anything shorter is passed through.
                let start = scan + 1
                let end = min(start + 4, chars.count)
                let hex = String(chars[start..<end])
                if hex.count == 4, let scalarValue = UInt32(hex, radix: 16),
                    let scalar = Unicode.Scalar(scalarValue)
                {
                    out.append(Character(scalar))
                    scan = end - 1
                } else {
                    out.append(chars[scan])
                }
            default: out.append(chars[scan])
            }
            scan += 1
        }
        // Unterminated literal: leave the cursor where recovery can find the
        // next `;`.
        index = scan
        return nil
    }
}

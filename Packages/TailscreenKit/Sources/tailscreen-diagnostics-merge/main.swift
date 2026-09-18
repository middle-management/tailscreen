import Foundation
import TailscreenProtocol

// Merge diagnostics bundles into one ordered timeline.
//
//     swift run --package-path Packages/TailscreenKit \
//       tailscreen-diagnostics-merge sharer.jsonl viewer.jsonl
//
// or `make merge-diagnostics FILES="sharer.jsonl viewer.jsonl"`.
//
// This exists because the merge was the point of recording two sides and had
// no way to be run: `DiagnosticsMerge` and `DiagnosticsExport.renderTimeline`
// shipped complete and tested, called from nothing but their own suites. The
// macOS app can export one bundle; nothing could read a pair.
//
// Deliberately thin. Every decision here — the pairing, the clock-skew solve,
// the ordering, the rendering — belongs to the library and is pinned by
// `DiagnosticsBundleTests` and `DiagnosticsExportTests`. What this file owns
// is argument handling and saying which file failed, so it is not worth a
// suite of its own.
//
// It depends on `TailscreenProtocol` alone, which is the Foundation-only
// tier — so it needs no `libtailscale.a`, no Go and no libopus, and anyone
// holding a pair of bundles can build it with nothing but a Swift toolchain.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    fail(
        """
        usage: tailscreen-diagnostics-merge <bundle.jsonl> [more.jsonl ...]

        Merges exported Tailscreen diagnostics bundles into one ordered
        timeline on stdout. The machines' clocks do not need to agree — the
        offset is solved from the handshake the two sides share.

        One file is allowed: it renders that bundle's own timeline.
        """,
        code: 2)
}

var bundles: [DiagnosticsBundle] = []
for path in paths {
    let text: String
    do {
        text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    } catch {
        // Name the file. A merge is run with several paths and a bare
        // "couldn't read it" leaves the reader guessing which.
        fail("\(path): could not be read — \(error.localizedDescription)", code: 1)
    }
    do {
        bundles.append(try DiagnosticsBundle.parse(jsonLines: text))
    } catch {
        fail("\(path): not a diagnostics bundle — \(error)", code: 1)
    }
}

print(DiagnosticsExport.renderTimeline(DiagnosticsMerge.merge(bundles)), terminator: "")

import Foundation
import TailscreenProtocol

// Merge diagnostics bundles into one ordered timeline.
//
//     swift run --package-path Packages/TailscreenKit \
//       tailscreen-diagnostics-merge sharer.jsonl viewer.jsonl
//
// or `make merge-diagnostics FILES="sharer.jsonl viewer.jsonl"`.
//
// Deliberately thin: the pairing, clock-skew solve, ordering, and rendering
// belong to the library and are pinned by `DiagnosticsBundleTests` and
// `DiagnosticsExportTests`. This file owns only argument handling and
// naming which file failed.
//
// Depends on `TailscreenProtocol` alone (Foundation-only), so it needs no
// `libtailscale.a`, Go, or libopus.

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
        // Name the file — a bare "couldn't read it" leaves the reader
        // guessing which of several paths failed.
        fail("\(path): could not be read — \(error.localizedDescription)", code: 1)
    }
    do {
        bundles.append(try DiagnosticsBundle.parse(jsonLines: text))
    } catch {
        fail("\(path): not a diagnostics bundle — \(error)", code: 1)
    }
}

print(DiagnosticsExport.renderTimeline(DiagnosticsMerge.merge(bundles)), terminator: "")

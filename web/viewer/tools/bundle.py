#!/usr/bin/env python3
"""Fold the browser viewer into ONE HTML file — dist/tailscreen-viewer.html.

For the deployment that cannot (or will not) serve a directory: an
air-gapped network, a file share, an attachment. Everything the page loads
by URL — wasm_exec.js, wire.js, viewer.js, strings.json, and the wasm itself
(gzip-compressed, base64) — is inlined; the loader in viewer.js recognises
the inlined form and inflates it with DecompressionStream, exactly as it
inflates the served viewer.wasm.gz. Open it as a file, append #tc… to its
URL, and it dials.

    make web-viewer-bundle
"""

import base64
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.path.normpath(os.path.join(HERE, ".."))
DIST = os.path.join(VIEWER, "dist")


def read(*parts, mode="r"):
    with open(os.path.join(*parts), mode, encoding=None if "b" in mode else "utf-8") as f:
        return f.read()


def main() -> None:
    html = read(VIEWER, "index.html")
    wasm_b64 = base64.b64encode(read(DIST, "viewer.wasm.gz", mode="rb")).decode("ascii")
    inline = (
        "<script>\n"
        + read(DIST, "wasm_exec.js")
        + "\n</script>\n<script>\n"
        + read(VIEWER, "wire.js")
        + "\n</script>\n<script>\n"
        + "window.__tailscreenInlineStrings = "
        + read(DIST, "strings.json")
        + ";\n"
        + 'window.__tailscreenInlineWasmGzB64 = "'
        + wasm_b64
        + '";\n</script>\n<script>\n'
        + read(VIEWER, "viewer.js")
        + "\n</script>\n"
    )
    # Replace the three external script tags with the inlined block.
    html, n = re.subn(r'<script src="[^"]+"></script>\s*', "", html)
    assert n == 3, f"expected 3 script tags, found {n}"
    html = html.replace("</div>\n", "</div>\n" + inline, 1) if inline not in html else html
    out = os.path.join(DIST, "tailscreen-viewer.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"{out}: {os.path.getsize(out) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()

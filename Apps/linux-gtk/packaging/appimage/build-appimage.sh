#!/usr/bin/env bash
#
# build-appimage.sh — assemble a Tailscreen AppImage from a release build
# of the swift-cross-ui/GTK viewer (Apps/linux-gtk).
#
# STATUS: structurally complete, NOT verified end-to-end in CI (needs a real GTK4
# toolchain, GPU/GL libs, and a live network for SwiftPM + the libtailscale Go
# build). See packaging/README.md.
#
# Required tools (install separately; NOT bundled here):
#   - swift            Swift 6 toolchain (swift.org)
#   - go, make, cc     to compile libtailscale.a (the tsnet C archive)
#   - GTK4 + dev libs  libgtk-4-dev, libepoxy-dev, libglib2.0-dev, pkg-config
#   - A/V + audio      libavcodec-dev, libavutil-dev, libasound2-dev, libopus-dev
#   - linuxdeploy      https://github.com/linuxdeploy/linuxdeploy  (+ the
#                      linuxdeploy-plugin-gtk plugin to pull in GTK's runtime
#                      data: themes, GDK loaders, gio modules)
#   - appimagetool     https://github.com/AppImage/appimagetool  (invoked by
#                      linuxdeploy when --output appimage is passed)
#   - rsvg-convert     (optional) librsvg, to render the app icon from the SVG
#
# A live network is required: the first build downloads Go modules and SwiftPM
# resolves swift-cross-ui.
#
# Usage:
#   Apps/linux-gtk/packaging/appimage/build-appimage.sh
#   OUTPUT=/tmp/Tailscreen.AppImage Apps/linux-gtk/packaging/appimage/build-appimage.sh
#
set -euo pipefail

# --- Locate the repo root (this script lives at Apps/linux-gtk/packaging/appimage). ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

APP_ID="dev.tailscreen.Tailscreen"
BIN_NAME="tailscreen"
ICON_NAME="tailscreen"                 # AppImage icon basename (matches Icon= below)
BUILD_DIR="Apps/linux-gtk/.build/release"
APPDIR="${APPDIR:-$REPO_ROOT/Apps/linux-gtk/.build/AppDir}"
OUTPUT="${OUTPUT:-$REPO_ROOT/Tailscreen-x86_64.AppImage}"

echo "==> Checking required tools"
missing=0
for tool in swift go make cc pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || { echo "  MISSING: $tool"; missing=1; }
done
command -v linuxdeploy >/dev/null 2>&1 \
  || { echo "  MISSING: linuxdeploy (see header for URL)"; missing=1; }
if [ "$missing" -ne 0 ]; then
  echo "error: install the missing tools above and re-run." >&2
  exit 1
fi

echo "==> Building libtailscale.a (Go c-archive + Swift glue)"
GOFLAGS=-buildvcs=false make -C Packages/TailscaleKit

echo "==> Building the viewer (release)"
# Build the executable product specifically so SwiftPM prunes to the Linux
# backend subgraph (DefaultBackend -> GtkBackend) and skips WinUI.
PKG_CONFIG_PATH="$REPO_ROOT/Packages/TailscaleKit${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  swift build -c release --package-path Apps/linux-gtk --product "$BIN_NAME"

BIN_PATH="$BUILD_DIR/$BIN_NAME"
[ -x "$BIN_PATH" ] || { echo "error: expected binary not found at $BIN_PATH" >&2; exit 1; }

echo "==> Assembling AppDir at $APPDIR"
rm -rf "$APPDIR"
install -Dm755 "$BIN_PATH" "$APPDIR/usr/bin/$BIN_NAME"

# Desktop entry (generated here so the AppImage Icon= matches the icon basename).
install -d "$APPDIR/usr/share/applications"
cat > "$APPDIR/usr/share/applications/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Tailscreen
GenericName=Screen Sharing
Comment=Share and view screens peer-to-peer over Tailscale
Exec=$BIN_NAME
Icon=$ICON_NAME
Terminal=false
Categories=Network;RemoteAccess;Utility;
Keywords=screen;share;remote;tailscale;viewer;sharing;
StartupNotify=true
EOF

# Icon. Prefer a real PNG if one has been added under packaging/icons/; otherwise
# render one from the project SVG; otherwise fall back to a 1x1 placeholder so the
# AppImage still assembles (a real icon is a documented follow-up — see README).
install -d "$APPDIR/usr/share/icons/hicolor/256x256/apps"
ICON_DEST="$APPDIR/usr/share/icons/hicolor/256x256/apps/$ICON_NAME.png"
PREBUILT_ICON="Apps/linux-gtk/packaging/icons/$APP_ID.png"
if [ -f "$PREBUILT_ICON" ]; then
  echo "    using prebuilt icon $PREBUILT_ICON"
  install -Dm644 "$PREBUILT_ICON" "$ICON_DEST"
elif command -v rsvg-convert >/dev/null 2>&1 && [ -f docs/assets/app-icon.svg ]; then
  echo "    rendering icon from docs/assets/app-icon.svg"
  rsvg-convert -w 256 -h 256 docs/assets/app-icon.svg -o "$ICON_DEST"
else
  echo "    WARNING: no icon available — writing a 1x1 placeholder (see README)."
  # Minimal valid 1x1 transparent PNG.
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$ICON_DEST"
fi
# linuxdeploy also expects the icon and .desktop at the AppDir root.
cp "$ICON_DEST" "$APPDIR/$ICON_NAME.png"

# AppRun: set up the bundle's library/data search paths, then exec the binary.
cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/bin/tailscreen" "$@"
EOF
chmod +x "$APPDIR/AppRun"

echo "==> Bundling dependencies + building AppImage with linuxdeploy"
# The gtk plugin (if installed) pulls in GTK's runtime data (themes, pixbuf
# loaders, gio modules). It is optional; linuxdeploy runs without it but the
# resulting AppImage may miss GTK theming data on minimal hosts.
DEPLOY_ARGS=(--appdir "$APPDIR"
             --executable "$APPDIR/usr/bin/$BIN_NAME"
             --desktop-file "$APPDIR/usr/share/applications/$APP_ID.desktop"
             --icon-file "$APPDIR/$ICON_NAME.png"
             --output appimage)
if linuxdeploy --list-plugins 2>/dev/null | grep -q '\bgtk\b'; then
  DEPLOY_ARGS+=(--plugin gtk)
else
  echo "    note: linuxdeploy-plugin-gtk not found; bundling without it."
fi

OUTPUT="$OUTPUT" linuxdeploy "${DEPLOY_ARGS[@]}"

echo "==> Done: $OUTPUT"

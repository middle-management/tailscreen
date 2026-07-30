#!/usr/bin/env bash
# Stage the self-contained Windows App SDK runtime beside the exe.
#
#   stage-winappsdk.sh <x64|arm64> [dist-dir]
#
# Downloads Microsoft.WindowsAppSDK from nuget.org (plain curl — no nuget.exe),
# extracts the per-arch FRAMEWORK package MSIX from tools/MSIX/win10-<arch>/,
# and copies its payload next to the app following the allowlist in Microsoft's
# own build/Microsoft.WindowsAppSDK.SelfContained.targets — this script is that
# msbuild target transcribed for a SwiftPM app. With the payload in place (and
# the reg-free WinRT manifest embedded — see gen-regfree-manifest.py) the app
# needs no installed Windows App Runtime and the MSIX needs no
# <PackageDependency>. The DDLM/Main/Singleton packages are deliberately not
# staged: only push/app-notification APIs need the Singleton (we use none), per
# Microsoft's self-contained deployment guide.
#
# The nupkg download is cached in $WASDK_CACHE (default .winappsdk-cache/) so
# an actions/cache hit skips the ~80 MB fetch; the payload is re-staged every
# run since staging is cheap and dist/ is rebuilt anyway.
set -euo pipefail

arch="${1:?usage: stage-winappsdk.sh <x64|arm64> [dist-dir]}"
dist="${2:-dist}"
case "$arch" in x64|arm64) ;; *) echo "arch must be x64 or arm64" >&2; exit 2 ;; esac

# Keep in lockstep with swift-winui's Windows App SDK pin: its
# WindowsAppSDK-VersionInfo.h says WINDOWSAPPSDK_RELEASE_MAJORMINOR=0x00010005
# (the 1.5 line), and 1.5.250108004 is the last 1.5 servicing release — the
# same one swift-winui's Bundler.toml pins for its installer. Staging a 1.6+
# payload against 1.5-generation projections is untested territory; bump this
# only together with the swift-winui revision.
ver="${WASDK_VERSION:-1.5.250108004}"

cache="${WASDK_CACHE:-.winappsdk-cache}"
mkdir -p "$cache"
nupkg="$cache/microsoft.windowsappsdk.$ver.nupkg"
if [ ! -f "$nupkg" ]; then
  echo "downloading Microsoft.WindowsAppSDK $ver"
  curl -fsSL -o "$nupkg.tmp" \
    "https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk/$ver/microsoft.windowsappsdk.$ver.nupkg"
  mv "$nupkg.tmp" "$nupkg"
else
  echo "using cached $nupkg"
fi

major_minor="${ver%.*}"   # 1.5.250108004 -> 1.5
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Extraction via Python, not unzip: Git Bash on the Windows runners does not
# ship unzip, and Python is on every GitHub image (and already required for
# gen-regfree-manifest.py below).
PY="$(command -v python3 || command -v python)"
[ -n "$PY" ] || { echo "no python interpreter found" >&2; exit 1; }

"$PY" - "$nupkg" "tools/MSIX/win10-$arch/Microsoft.WindowsAppRuntime.$major_minor.msix" "$work" <<'PYEOF'
import sys, zipfile, pathlib
nupkg, member, dest = sys.argv[1:4]
dest = pathlib.Path(dest)
with zipfile.ZipFile(nupkg) as z:
    for name in (member, "license.txt", "NOTICE.txt"):
        data = z.read(name)
        (dest / pathlib.Path(name).name).write_bytes(data)
PYEOF
mkdir -p "$work/payload"
"$PY" -m zipfile -e "$work/Microsoft.WindowsAppRuntime.$major_minor.msix" "$work/payload"

mkdir -p "$dist"
distabs="$(cd "$dist" && pwd)"

# The SelfContained.targets allowlist, subdirectories preserved. Everything
# else in the framework MSIX (AppxManifest.xml, DeploymentAgent.exe, the
# nested MSIX/, *.man) is consumed at build time or MSIX-machinery-only and is
# excluded by not being copied.
#
# Python, not `find | xargs cp`: on both Windows runners, cp deterministically
# failed to CREATE dist/Microsoft.WindowsAppRuntime.Bootstrap.dll with a bare
# "Permission denied" — that one file, both arches, no pre-existing dest, and
# the identical pipeline is clean on Linux. MSYS cp cannot say WHY; Python's
# OSError carries the Windows error code (5 = access denied, 32 = sharing
# violation from an AV scan, 225 = Defender "contains a virus or potentially
# unwanted software"), so a failure here names the mechanism instead of
# guessing. Each file gets an unlink-first (a read-only dest from an earlier
# stage would EACCES a plain overwrite) and one delayed retry (rides out a
# scan-lock); a final failure still fails the script.
"$PY" - "$work/payload" "$distabs" <<'PYEOF'
import os
import shutil
import sys
import time

src_root, dist = sys.argv[1], sys.argv[2]
exts = {".dll", ".mui", ".png", ".winmd", ".xaml", ".xbf", ".pri"}
names = {"RestartAgent.exe", "map.html"}
failed = []
copied = 0
for root, _dirs, files in os.walk(src_root):
    for name in files:
        if os.path.splitext(name)[1].lower() not in exts and name not in names:
            continue
        src = os.path.join(root, name)
        rel = os.path.relpath(src, src_root)
        dst = os.path.join(dist, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        for attempt in (1, 2):
            try:
                if os.path.exists(dst):
                    os.chmod(dst, 0o666)
                    os.unlink(dst)
                shutil.copyfile(src, dst)
                copied += 1
                break
            except OSError as e:
                win = getattr(e, "winerror", None)
                print(f"copy {rel} attempt {attempt}: {e!r} winerror={win}",
                      file=sys.stderr)
                if attempt == 2:
                    failed.append(rel)
                else:
                    time.sleep(2)
print(f"copied {copied} payload files")
if failed:
    print(f"FAILED to stage: {failed}", file=sys.stderr)
    sys.exit(1)
PYEOF

# WinUI probes for the app-local resource index under this name; the rename
# also keeps it from colliding with an app's own resources.pri. Same step as
# SelfContained.targets.
mv "$distabs/resources.pri" "$distabs/Microsoft.UI.Xaml.Controls.pri"

# License terms travel with the redistributed runtime (license.txt section 3,
# Distributable Code). Prefixed names so they cannot shadow app-level files.
cp "$work/license.txt" "$distabs/Microsoft.WindowsAppSDK.license.txt"
cp "$work/NOTICE.txt" "$distabs/Microsoft.WindowsAppSDK.NOTICE.txt"

# Hard sanity: the load-bearing DLLs exist and are the arch we were asked for.
# A cross-arch payload would not error until first launch on a user's machine —
# the same failure shape as the x64-vcruntime-in-the-arm64-dist bug this
# repo already met once.
pe_machine() {
  off=$(od -An -tu4 -j 60 -N 4 "$1" | tr -d ' ')
  od -An -tx2 -j "$((off + 4))" -N 2 "$1" | tr -d ' '
}
want=$([ "$arch" = arm64 ] && echo aa64 || echo 8664)
for dll in Microsoft.WindowsAppRuntime.dll Microsoft.ui.xaml.dll; do
  [ -f "$distabs/$dll" ] || { echo "staging incomplete: $dll missing" >&2; exit 1; }
  got=$(pe_machine "$distabs/$dll")
  [ "$got" = "$want" ] || {
    echo "arch mismatch: $dll is PE machine $got, wanted $want ($arch)" >&2
    exit 1
  }
done

# The reg-free WinRT manifest, generated from the SAME MSIX the DLLs came
# from so the two can never skew. CI must embed it with mt.exe (see
# gen-regfree-manifest.py's header for why embedding is mandatory).
"$PY" "$(cd "$(dirname "$0")" && pwd)/gen-regfree-manifest.py" \
  "$work/payload/AppxManifest.xml" \
  "$distabs/tailscreen.exe.manifest" \
  --verify-dist "$distabs"

staged=$(cd "$work/payload" && find . -type f | wc -l)
echo "staged Windows App SDK $ver ($arch) framework payload into $dist ($staged files in MSIX)"

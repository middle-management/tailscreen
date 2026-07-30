#!/usr/bin/env bash
# The app staging logic, extracted VERBATIM from windows-build.yml's inline
# step when the arm64 leg needed the same thing — the alternative was a second
# 184-line copy that would agree with this one until it didn't.
#
# Deliberately ARCH-NEUTRAL, which it already was: it stages whatever exe the
# build produced, takes the Swift runtime from whichever toolchain is on PATH,
# and leaves architecture agreement to the PE-machine-type check that runs
# after it. Inputs: OPUS_ROOT and FFMPEG_ROOT env vars; output: dist/.
# Also runnable locally on a Windows machine with git-bash, which the inline
# version never was — the arm64-bootstrapper-beside-an-x64-exe bug shipped
# precisely because nobody could run this without pushing a commit.
set -euo pipefail

# Scoped to the release directory, not just the name. The build
# cache restores the whole .build tree, so a debug exe from before
# the switch to release config can still be sitting there — and an
# unscoped `head -1` would happily ship it, which is the one binary
# this change exists to stop shipping.
exe=$(find Apps/windows/.build -path '*/release/*' -name 'tailscreen.exe' | head -1)
if [ -z "$exe" ]; then
  echo "no tailscreen.exe produced" >&2
  exit 1
fi
ls -la "$exe"
mkdir -p dist
cp "$exe" dist/tailscreen.exe

# The diagnostic probe rides along: it shares every staged runtime DLL
# with the app, so shipping it costs one file and saves the user a
# second download when the app misbehaves.
#
# Located the same way as the app, and for the same reason the first
# version of this was wrong: THIS STEP HAS NO `working-directory`, so
# it runs at the repo root while the two build steps above run in
# Apps/windows. A relative `.build/…` path therefore missed, and
# because the miss was written as a skippable note the artifact
# shipped without the probe and the job still went green — the same
# shape of hole as a missing path filter. It is a hard failure now:
# the build step above is unconditional, so if the exe is absent here
# something is wrong with this step, not with the build.
probe=$(find Apps/windows/.build -path '*/release/*' -name 'tsnet-probe.exe' | head -1)
if [ -z "$probe" ]; then
  echo "no tsnet-probe.exe produced" >&2
  exit 1
fi
cp "$probe" dist/tsnet-probe.exe

# The toolchain ships the runtime and the COMPILER in one bin
# directory, so copying every DLL beside swiftCore.dll produced a
# 1.1 GB artifact: liblldb (160 MB), sourcekitdInProc (150 MB),
# _InternalSwiftScan (150 MB), libclang (84 MB) and all of SwiftPM's
# own libraries, none of which an app loads. Hence an explicit list of
# what a Swift program actually links against.
#
# A name list can go stale when a toolchain adds or renames a runtime
# library — which is why the load check below is not optional. It is
# what makes an allow-list safe: anything missing from this list shows
# up as STATUS_DLL_NOT_FOUND on the runner, not on a tester's desktop.
#
# No bare `swift*.dll` glob: the compiler DLLs are `SwiftSyntax.dll`,
# `SwiftParser.dll` and friends, and one case-insensitive match would
# quietly put the 1.1 GB back.
runtime_dlls=(
  swiftCore.dll swiftCRT.dll swiftWinSDK.dll swiftDispatch.dll
  swiftSynchronization.dll swiftObservation.dll swiftRegexBuilder.dll
  swiftSwiftOnoneSupport.dll swiftDistributed.dll
  'swift_*.dll'
  'Foundation*.dll' '_Foundation*.dll'
  dispatch.dll BlocksRuntime.dll
  'vcruntime140*.dll' 'msvcp140*.dll' concrt140.dll vccorlib140.dll
)

found=0
while IFS= read -r d; do
  [ -d "$d" ] || continue
  if compgen -G "$d/swiftCore.dll" > /dev/null || compgen -G "$d/Foundation*.dll" > /dev/null; then
    echo "runtime dir: $d"
    for pattern in "${runtime_dlls[@]}"; do
      compgen -G "$d/$pattern" > /dev/null || continue
      cp -n "$d"/$pattern dist/ 2>/dev/null || true
    done
    found=$((found + 1))
  fi
done < <(echo "$PATH" | tr ':' '\n')

if [ "$found" -eq 0 ]; then
  echo "no Swift runtime directory found on PATH" >&2
  exit 1
fi

# SwiftPM RESOURCE BUNDLES — directories, and their structure is
# load-bearing.
#
# swift-winui looks for the Windows App SDK bootstrapper at an exact
# relative path beside the executable:
#
#   swift-winui_CWinAppSDK.resources\Microsoft.WindowsAppRuntime.Bootstrap.dll
#
# and when it isn't there it throws, which SwiftApplication.main turns
# into fatalError("fatal"). A previous version of this step swept
# `find .build -name '*.dll'` into a FLAT dist/, which put that DLL
# (if it copied it at all) somewhere the lookup does not check — so
# the app died at startup on every machine including the runner,
# having loaded every library it needed. Copy the directories.
exedir=$(dirname "$exe")
shopt -s nullglob
for bundle in "$exedir"/*.resources "$exedir"/*.bundle; do
  [ -d "$bundle" ] || continue
  echo "resource bundle: $(basename "$bundle")"
  cp -R "$bundle" dist/
done
shopt -u nullglob

# If the Windows App Runtime is absent from the test machine, the
# bootstrapper runs this installer when it sits beside the exe, rather
# than popping a "go download it" dialog. Worth shipping: the whole
# point of the artifact is that a tester needs nothing preinstalled.
installer=$(find Apps/windows/.build -name 'WindowsAppRuntimeInstaller.exe' | head -1)
if [ -n "$installer" ]; then
  echo "runtime installer: $installer"
  cp "$installer" dist/
else
  echo "note: no WindowsAppRuntimeInstaller.exe in the build tree;" \
       "a machine without the Windows App Runtime will be prompted to install it"
fi

# Any remaining loose DLLs in the build tree, after the bundles so a
# flat copy can never stand in for a structured one.
# ARCH-GATED, unlike every copy above it, because this sweep is the one that
# cannot trust its source: the WindowsAppSDK/swift-winui NuGet payload inside
# .build ships BOTH architectures' DLLs side by side, and an unfiltered cp -n
# takes whichever find meets first. On arm64 that staged an x64
# vcruntime140_1.dll beside the AA64 exe — the bootstrapper bug in mirror
# image, caught by the arch check this time. Only DLLs whose PE machine type
# matches the exe's own are eligible.
pe_machine() {
  local off
  off=$(od -An -tu4 -j 60 -N 4 "$1" 2>/dev/null | tr -d ' ')
  [ -n "$off" ] || { echo 0000; return; }
  od -An -tx2 -j $((off + 4)) -N 2 "$1" 2>/dev/null | tr -d ' '
}
app_machine=$(pe_machine dist/tailscreen.exe)
echo "app PE machine: $app_machine"
while IFS= read -r dll; do
  m=$(pe_machine "$dll")
  if [ "$m" = "$app_machine" ]; then
    cp -n "$dll" dist/ 2>/dev/null || true
  else
    echo "skipping $(basename "$dll") ($m != $app_machine)"
  fi
done < <(find Apps/windows/.build -maxdepth 4 -name '*.dll')

# libopus. vcpkg's x64-windows triplet builds SHARED libraries, so the
# app links an import library and needs opus.dll at run time. It lives
# in vcpkg's bin/, which is not on the PATH scan above (that only
# walks directories holding Swift/Foundation DLLs). libtailscale needs
# no equivalent — it is a static archive.
opus_root="${OPUS_ROOT:-}"
if [ -n "$opus_root" ] && [ -d "$opus_root/bin" ]; then
  cp -n "$opus_root"/bin/*.dll dist/ 2>/dev/null || true
  ls "$opus_root/bin/"
else
  echo "note: no vcpkg opus bin/ — a shared libopus would be missing" >&2
fi

# libavcodec and friends, for the same reason: BtbN's is a SHARED
# build, so the exe carries import libraries and needs the DLLs. The
# architecture gate below checks these too, which is worth having —
# this is a third-party archive, not something we compiled.
ffmpeg_root=$(cygpath -u "${FFMPEG_ROOT:-}" 2>/dev/null || echo "${FFMPEG_ROOT:-}")
if [ -n "$ffmpeg_root" ] && [ -d "$ffmpeg_root/bin" ]; then
  cp -n "$ffmpeg_root"/bin/*.dll dist/ 2>/dev/null || true
else
  echo "note: no FFmpeg bin/ — video decode would fail at load" >&2
fi

# FINAL PASS: no top-level DLL survives with the wrong architecture, whatever
# copy path brought it in. The sweep above was gated and the arch check STILL
# failed — the PATH runtime harvest also matches vcruntime140*.dll, and a PATH
# dir that qualifies via swiftCore.dll/Foundation*.dll can still hold x64 VC
# redistributables beside them. Enumerating every such source is a losing game;
# deleting mismatches once, here, ends it. The swiftCore/bootstrapper
# assertions below still run AFTER this, so an over-eager delete fails loudly
# instead of shipping quietly.
for dll in dist/*.dll; do
  [ -f "$dll" ] || continue
  m=$(pe_machine "$dll")
  if [ "$m" != "$app_machine" ]; then
    echo "removing $(basename "$dll") ($m != $app_machine)"
    rm -f "$dll"
  fi
done

if [ ! -f dist/swiftCore.dll ]; then
  echo "swiftCore.dll was not staged — the artifact would not run" >&2
  exit 1
fi

# Assert the exact path the app will look up, not an approximation of
# it. This is the invariant whose violation produced a green build and
# an app that quit instantly.
if [ ! -f dist/swift-winui_CWinAppSDK.resources/Microsoft.WindowsAppRuntime.Bootstrap.dll ] \
   && [ ! -f dist/swift-winui_CWinAppSDK.bundle/Microsoft.WindowsAppRuntime.Bootstrap.dll ]; then
  echo "FAILED: the Windows App SDK bootstrapper is not at the path swift-winui looks up." >&2
  echo "The app would print 'Expected to find bootstrapper dll at one of ...' and abort." >&2
  find Apps/windows/.build -name 'Microsoft.WindowsAppRuntime.Bootstrap.dll' >&2 || true
  exit 1
fi

ls -la dist/
du -sh dist/

      # Every staged binary must be the app's architecture.
      #
      # swift-winui carries BOTH arm64 and x86_64 copies of
      # Microsoft.WindowsAppRuntime.Bootstrap.dll in its source tree, and its
      # manifest picks between them with #if arch(...). The old flat sweep
      # ignored that: `find` yields arm64/ before x86_64/, and `cp -n` took the
      # first and then declined to overwrite it — so the artifact shipped an
      # ARM64 bootstrapper beside an x64 exe. An x64 process cannot load an
      # ARM64 DLL, so it failed with "Failed to load bootstrapper dll", which
      # reads like a missing-file problem and is not one. Reported from a
      # Windows-on-ARM VM, where PowerShell (itself ARM64) loaded the same DLL
      # happily — a detail that makes the mismatch easy to misread.
      #
      # Checking the whole directory rather than just that one DLL: the defect
      # was "a wrong-architecture file got staged", and nothing makes the
      # bootstrapper the only file that can happen to.

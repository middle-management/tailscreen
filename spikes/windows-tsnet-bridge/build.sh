#!/usr/bin/env bash
# Cross-build the Windows bridge spike from a Linux host.
#
# This only proves the spike COMPILES and LINKS for Windows — running it needs
# an actual Windows machine (or the `windows-spike` CI job, which does both).
#
# Needs: Go, and mingw-w64 (`apt-get install gcc-mingw-w64-x86-64`).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Leg A: compile the pure-Go primitives for windows/amd64"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build ./...

echo "==> Leg B: c-archive (cgo, mingw)"
GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc \
  go build -buildmode=c-archive -o spike.a .

echo "==> Leg B: link the C harness"
x86_64-w64-mingw32-gcc -I. -o harness.exe harness/harness.c spike.a \
  -lws2_32 -lntdll -lbcrypt -lwinmm -luserenv -lsynchronization -ladvapi32 -lkernel32

file harness.exe
echo
echo "Built. Run harness.exe on Windows, or let the windows-spike CI job do it."

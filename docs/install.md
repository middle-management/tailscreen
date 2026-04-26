---
title: Install
nav_order: 2
permalink: /install/
---

# Install
{: .no_toc }

1. TOC
{:toc}

## Prebuilt release

The simplest path is to grab the latest signed, notarized
`Tailscreen-<version>-macOS.zip` from the
[Releases page](https://github.com/middle-management/tailscreen/releases),
unzip it, and drag `Tailscreen.app` into `/Applications`.

The release is a universal Mach-O (`arm64` + `x86_64`), built by the
`release.yml` GitHub Actions workflow on `macos-15`.

## Build from source

Tailscreen is Swift Package Manager only — there is no Xcode project. The
top-level [`Makefile`](https://github.com/middle-management/tailscreen/blob/main/Makefile)
is the build entry point because it sets `PKG_CONFIG_PATH` so SwiftPM can
find `libtailscale.pc`.

### Prerequisites

- macOS 15.0 (Sequoia) or later
- Swift 6.0 toolchain
- **Go 1.21+** — required at build time to compile `libtailscale.a`, the C
  archive that TailscaleKit wraps. The Go toolchain is *not* needed at
  runtime.

### Clone with submodules

`TailscaleKitPackage/upstream/libtailscale` is a git submodule. Clone with
`--recurse-submodules`, or run the init step after cloning:

```bash
git clone --recurse-submodules https://github.com/middle-management/tailscreen.git
# or, after a regular clone:
git submodule update --init --recursive
```

### Build

```bash
make build
```

This will:

1. Build the `libtailscale` C archive from the upstream submodule (Go).
2. Apply the patches under `TailscaleKitPackage/Patches/` to the upstream
   Swift sources.
3. Build the Swift TailscaleKit wrapper.
4. Build the Tailscreen application.

The first build downloads Go modules, so network access is required.

### Run

```bash
make run
# or, manually:
.build/debug/Tailscreen
```

### Release build

```bash
make release
# binary: .build/release/Tailscreen
```

### Install to `~/bin`

```bash
make install
```

## Permissions

On first launch, macOS will prompt for **Screen Recording** permission. Grant
it in **System Settings → Privacy & Security → Screen Recording**, then quit
and relaunch Tailscreen so the new permission is picked up.

## Troubleshooting the build

- **`swift build` fails with linker errors** — you skipped `make tailscale` /
  `make build`. The Go build produces `libtailscale.a`; without it nothing
  links. Always go through `make`.
- **Submodule directory looks empty** — run
  `git submodule update --init --recursive`.
- **Want to modify TailscaleKit's Swift sources** — don't edit
  `TailscaleKitPackage/Sources/` directly; those paths are symlinks into the
  submodule. Add a patch under `TailscaleKitPackage/Patches/` and re-run
  `make tailscale`.

More detail in [Contributing]({% link contributing.md %}).

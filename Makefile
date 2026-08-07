.PHONY: help build run clean release install tailscale test test-protocol test-tsan test-l10n lint lint-baseline format format-check print-format-paths-all e2e-up e2e-down test-e2e test-e2e-local test-e2e-harness icon

# Default target: print a one-line summary of every target. Targets are
# self-documented via the `## description` suffix on each rule.
.DEFAULT_GOAL := help

# Lets SwiftPM's systemLibrary targets find their `.pc` files at build time:
#   - libtailscale.pc (TailscaleKit), which resolves the `-L` for
#     libtailscale.a, and
#   - opus.pc (OpusKit's COpus wrapper over libopus).
# SwiftPM's own pkg-config resolver does NOT search Homebrew's prefix on
# Apple Silicon, so add `$(brew --prefix)/lib/pkgconfig` explicitly (empty +
# harmless when brew is absent, e.g. Linux, where opus.pc is on the default
# path). Any inherited PKG_CONFIG_PATH is appended so a custom prefix wins.
BREW_PKGCONFIG := $(shell brew --prefix 2>/dev/null)/lib/pkgconfig
export PKG_CONFIG_PATH := $(CURDIR)/Packages/TailscaleKit:$(BREW_PKGCONFIG):$(PKG_CONFIG_PATH)

help: ## Show this help and exit
	@awk 'BEGIN { FS = ":.*## "; printf "Tailscreen — Make targets\n\nUsage: make <target>\n\nTargets:\n" } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# Build TailscaleKit C library if needed
tailscale: ## Build libtailscale.a via the TailscaleKit submodule
	@cd Packages/TailscaleKit && $(MAKE)

# Build with TailscaleKit dependency
build: tailscale ## Build the debug binary (libtailscale + swift build)
	cd Apps/macOS && swift build

run: tailscale ## Build + run the debug binary
	cd Apps/macOS && swift run

test: tailscale ## Run the unit test suite (swift test)
	cd Apps/macOS && swift test

# The platform-portable sub-package (wire protocol + pure decision logic +
# the tsnet-facing transport tier — see Packages/TailscreenKit/README.md).
# The app depends on it as a real SwiftPM dependency; the files live only in
# the package. Needs no Apple framework, so it also runs on Linux; CI's
# linux-protocol job runs exactly this. Compiling still needs only the
# patched header, but the test bundle LINKS libtailscale.a — the
# Tests/TailscreenSharerTests executable links TailscreenSharer, which
# names TailscaleKit — hence the full `tailscale` prerequisite (which
# also applies the patches).
test-protocol: tailscale ## Build + smoke-test the portable TailscreenKit package
	swift test --package-path Packages/TailscreenKit

# The shared string catalog (Packages/TailscreenL10n). Its suites are the ONLY
# check on the GTK and WinUI apps' user-facing strings: they scan all four
# source trees for `L("…")` keys and fail on any the catalog does not carry, and
# they exercise the `.strings` parser / language resolution / `%@` substitution
# that replaced Apple Foundation's. No dependencies at all, so it runs anywhere
# Swift does; CI's linux-l10n job runs exactly this.
test-l10n: ## Build + test the shared localization catalog package
	swift test --package-path Packages/TailscreenL10n

# Thread sanitizer build of the test suite. Catches data races on locks,
# double-resumed continuations, callback ordering bugs that compile fine
# under Swift 6 strict concurrency. Slower (~3x), so kept off `make test`.
test-tsan: tailscale ## Run tests under ThreadSanitizer
	cd Apps/macOS && swift test --sanitize=thread

# SwiftLint over the trees listed in `.swiftlint.yml`. Install once:
# `brew install swiftlint` (CI pins the version — see build.yml).
# Existing violations are frozen in .swiftlint-baseline.json; only NEW
# warnings/errors fail the run. Refresh baseline via `make lint-baseline`
# after a real cleanup pass.
lint: ## Run SwiftLint (baseline-gated; new violations fail)
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint missing — brew install swiftlint"; exit 1; }
	@swiftlint lint --baseline .swiftlint-baseline.json --strict --quiet

# The committed baseline is PRETTY-PRINTED, key-sorted and repo-RELATIVE.
# SwiftLint's own `--write-baseline` gives none of those: it emits one ~56 KB
# line (so every refresh is a one-line diff nobody can review, and a real
# regression rides along inside it) recording absolute paths (which suppress
# nothing on any other machine). Both used to be fixed by hand from a scratch
# directory; scripts/normalize-lint-baseline.py does it in-target instead, and
# explains the failure mode of each.
#
# python3 rather than jq: python3 is already a build/CI dependency (the Windows
# regfree-manifest generator, the e2e scripts), jq is not — and relativizing
# paths needs a script either way.
#
# Formatting and ordering are invisible to SwiftLint (it decodes the file as
# JSON), so normalizing can never change WHICH violations are frozen.
#
# SwiftLint's exit code is ignored on purpose: `lint --write-baseline` still
# reports the violations it just froze, and exits non-zero when any of them is
# error-severity — which is the normal state of a baseline refresh. The
# non-empty/parses/relativizes checks in the normalizer are what actually
# guard this target, and they run against a temp file so a crashed SwiftLint
# leaves the committed baseline untouched. `make lint` is the gate.
lint-baseline: ## Regenerate the SwiftLint baseline from current state
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint missing — brew install swiftlint"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "python3 missing — needed to normalize the baseline"; exit 1; }
	@rm -f .swiftlint-baseline.json.new
	@swiftlint lint --write-baseline .swiftlint-baseline.json.new --quiet || true
	@test -s .swiftlint-baseline.json.new || { echo "swiftlint wrote no baseline"; exit 1; }
	@python3 scripts/normalize-lint-baseline.py \
		.swiftlint-baseline.json.new .swiftlint-baseline.json "$(CURDIR)"
	@rm -f .swiftlint-baseline.json.new
	@echo "Wrote .swiftlint-baseline.json"

# Apple's swift-format ships with the Swift toolchain on macOS (Xcode 16+).
# `format` rewrites files in place; `format-check` is the lint-only mode
# used by CI. Config lives in `.swift-format` at the repo root.
#
# The GTK video-surface library (Apps/linux/Sources/TailscreenViewerGtk) is
# under the gate. The app's executable target (Apps/linux/Sources/tailscreen)
# and the Linux backends (Packages/TailscreenLinuxBackends/Sources) are NOT yet
# covered: they still carry pre-existing swift-format violations. Fold each in
# here once its tree is clean — FORMAT_PATHS_ALL below is the full list this
# is converging on, and says how to get there.
FORMAT_PATHS := Apps/macOS/Sources Apps/macOS/Tests Packages/TailscreenKit/Sources \
	Packages/TailscreenL10n/Sources Apps/linux/Sources/TailscreenViewerGtk

# The TARGET STATE for FORMAT_PATHS: every tree in the repo that carries Swift
# we own. NOT yet wired into `format` / `format-check` — the sweep that makes
# it pass is a separate commit (a repo-wide reformat conflicts with anything
# in flight, so it lands on its own). To do the sweep:
#
#     make format FORMAT_PATHS="$(make -s print-format-paths-all)"
#
# …review, commit, then make the switch permanent here (FORMAT_PATHS gets
# FORMAT_PATHS_ALL's value) and drop `continue-on-error: true` from the
# `format` job in .github/workflows/build.yml, which is what turns the check
# from advisory into required.
#
# What is deliberately NOT in the list:
#   • C/C++/ObjC shims (Packages/*/Sources/C*/**.c,.h and friends) — excluded
#     by construction, not by name: swift-format only touches *.swift, so
#     listing a Sources tree that also holds a shim target is safe.
#   • Packages/TailscaleKit/Sources — Sources/TailscaleKit is a SYMLINK into
#     the libtailscale submodule. Formatting it would rewrite upstream
#     BSD-licensed files through the symlink and make the patch series in
#     Packages/TailscaleKit/Patches/ stop applying. (Its sibling
#     Sources/CGoRuntimeInit is ours but is C-only, so the whole tree can go.
#     Packages/TailscaleKit/Tests is ours and stays in.)
#   • Package.swift manifests — they sit at package roots, not under any
#     Sources/ tree, so --recursive never reaches them; 25 manifests of churn
#     for no reviewer benefit.
#   • Anything generated — there is none in-tree today (checked: no
#     "DO NOT EDIT" Swift file exists), so no exclusion is needed. If a
#     generator ever lands, exclude its output here.
#
# Packages are picked up by wildcard so a new package is covered the day it
# lands rather than the day someone remembers this variable.
FORMAT_PATHS_ALL := Apps/macOS/Sources Apps/macOS/Tests \
	Apps/linux/Sources Apps/windows/Sources \
	$(filter-out Packages/TailscaleKit/Sources, $(wildcard Packages/*/Sources Packages/*/Tests))

print-format-paths-all: ## Print FORMAT_PATHS_ALL (the target-state format tree list)
	@echo '$(FORMAT_PATHS_ALL)'

format: ## Run swift-format in-place over the app package
	@command -v swift-format >/dev/null 2>&1 || { echo "swift-format missing — install Xcode 16+ or run 'brew install swift-format'"; exit 1; }
	@swift-format format --in-place --parallel --recursive $(FORMAT_PATHS)

format-check: ## Run swift-format in lint mode (no changes); CI uses this
	@command -v swift-format >/dev/null 2>&1 || { echo "swift-format missing — install Xcode 16+ or run 'brew install swift-format'"; exit 1; }
	@swift-format lint --strict --parallel --recursive $(FORMAT_PATHS)

release: tailscale ## Build the release binary (Apps/macOS/.build/release/Tailscreen)
	cd Apps/macOS && swift build -c release
	@echo "Binary available at: Apps/macOS/.build/release/Tailscreen"

clean: ## Wipe .build/ and the TailscaleKit build artifacts
	cd Apps/macOS && swift package clean
	rm -rf Apps/macOS/.build
	@cd Packages/TailscaleKit && $(MAKE) clean

install: release ## Build release + copy binary to ~/bin/Tailscreen
	@mkdir -p ~/bin
	@cp Apps/macOS/.build/release/Tailscreen ~/bin/
	@echo "Installed to ~/bin/Tailscreen"

# Bring up a local headscale control server for integration testing.
# Prints `export ...` lines on stdout; run via `eval "$$(make e2e-up)"`.
e2e-up: ## Start a local headscale (Docker) for connectivity tests
	@./scripts/e2e-up.sh

e2e-down: ## Tear down the local headscale + Docker volume
	@./scripts/e2e-down.sh

# One-shot: spin headscale, run the connectivity test, tear down.
test-e2e: tailscale ## End-to-end: e2e-up → connectivity tests → e2e-down
	@./scripts/e2e-test.sh

# Local-only screen-share E2E XCTest (synthetic frames + real capture-helper +
# picker-helper smoke). The capture-helper test self-skips on CI; the
# synthetic-frames test is CI-eligible but headscale-dependent.
test-e2e-local: tailscale build ## End-to-end (LOCAL): screen-share XCTest under headscale
	@./scripts/test-e2e-xctest.sh

# Two real Tailscreen processes, full UI pipeline, asserted by log marker.
# Needs Screen Recording permission granted to Apps/macOS/.build/debug/Tailscreen.
test-e2e-harness: tailscale build ## End-to-end (LOCAL): two-instance scripted harness
	@./scripts/test-e2e-local.sh

# Regenerate the macOS .icns app icon from the source SVG. Requires
# librsvg (`brew install librsvg`) and the system iconutil.
# app-icon.svg is the Dock/Finder artwork (logo glyph on a rounded-rect
# tile, standard Big Sur icon grid); logo.svg stays the bare glyph used
# by the README, docs, and in-app PDFs.
ICON_SRC := docs/assets/app-icon.svg
ICON_OUT := Apps/macOS/Resources/Tailscreen.icns
ICONSET  := Apps/macOS/Resources/Tailscreen.iconset

icon: ## Regenerate Tailscreen.icns + in-app PDFs from docs/assets/{app-icon,logo}.svg
	@command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert missing — brew install librsvg"; exit 1; }
	@command -v iconutil >/dev/null 2>&1 || { echo "iconutil missing — install Xcode command line tools"; exit 1; }
	@rm -rf "$(ICONSET)" && mkdir -p "$(ICONSET)"
	@for sz in 16 32 128 256 512; do \
		rsvg-convert -w $$sz -h $$sz "$(ICON_SRC)" -o "$(ICONSET)/icon_$${sz}x$${sz}.png"; \
		dbl=$$((sz * 2)); \
		rsvg-convert -w $$dbl -h $$dbl "$(ICON_SRC)" -o "$(ICONSET)/icon_$${sz}x$${sz}@2x.png"; \
	done
	@iconutil -c icns "$(ICONSET)" -o "$(ICON_OUT)"
	@rm -rf "$(ICONSET)"
	@echo "Wrote $(ICON_OUT)"
	@echo "Regenerating in-app PDFs…"
	@# Menubar PDFs are state-specific brand variants (idle TV outline,
	@# filled screen for sharing, outline + play triangle for viewing).
	@# WelcomeIcon uses the full with-stand artwork.
	@rsvg-convert -f pdf Apps/macOS/Sources/Resources/MenubarIcon.svg    -o Apps/macOS/Sources/Resources/MenubarIcon.pdf
	@rsvg-convert -f pdf Apps/macOS/Sources/Resources/MenubarSharing.svg -o Apps/macOS/Sources/Resources/MenubarSharing.pdf
	@rsvg-convert -f pdf Apps/macOS/Sources/Resources/MenubarViewing.svg -o Apps/macOS/Sources/Resources/MenubarViewing.pdf
	@rsvg-convert -f pdf docs/assets/logo.svg -o Apps/macOS/Sources/Resources/WelcomeIcon.pdf
	@echo "Wrote Apps/macOS/Sources/Resources/{MenubarIcon,MenubarSharing,MenubarViewing,WelcomeIcon}.pdf"

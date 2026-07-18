.PHONY: help build run clean release install tailscale test test-protocol test-tsan lint lint-baseline format format-check e2e-up e2e-down test-e2e test-e2e-local test-e2e-harness icon

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
# the package. Needs no built libtailscale.a and no Apple framework, so it
# also runs on Linux; CI's linux-protocol job runs exactly this. The
# TailscreenTransport target compiles against TailscaleKit, which needs the
# submodule checked out with patches applied (header only — no Go build),
# hence the apply-patches prerequisite.
test-protocol: ## Build + smoke-test the portable TailscreenProtocol package
	@$(MAKE) -C Packages/TailscaleKit apply-patches
	swift test --package-path Packages/TailscreenKit

# Thread sanitizer build of the test suite. Catches data races on locks,
# double-resumed continuations, callback ordering bugs that compile fine
# under Swift 6 strict concurrency. Slower (~3x), so kept off `make test`.
test-tsan: tailscale ## Run tests under ThreadSanitizer
	cd Apps/macOS && swift test --sanitize=thread

# SwiftLint over Sources/Tests/Examples. Install once: `brew install swiftlint`.
# Existing violations are frozen in .swiftlint-baseline.json; only NEW
# warnings/errors fail the run. Refresh baseline via `make lint-baseline`
# after a real cleanup pass.
lint: ## Run SwiftLint (baseline-gated; new violations fail)
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint missing — brew install swiftlint"; exit 1; }
	@swiftlint lint --baseline .swiftlint-baseline.json --strict --quiet

lint-baseline: ## Regenerate the SwiftLint baseline from current state
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint missing — brew install swiftlint"; exit 1; }
	@swiftlint lint --write-baseline .swiftlint-baseline.json --quiet
	@echo "Wrote .swiftlint-baseline.json"

# Apple's swift-format ships with the Swift toolchain on macOS (Xcode 16+).
# `format` rewrites files in place; `format-check` is the lint-only mode
# used by CI. Config lives in `.swift-format` at the repo root.
format: ## Run swift-format in-place over the app package
	@command -v swift-format >/dev/null 2>&1 || { echo "swift-format missing — install Xcode 16+ or run 'brew install swift-format'"; exit 1; }
	@swift-format format --in-place --parallel --recursive Apps/macOS/Sources Apps/macOS/Tests Packages/TailscreenKit/Sources

format-check: ## Run swift-format in lint mode (no changes); CI uses this
	@command -v swift-format >/dev/null 2>&1 || { echo "swift-format missing — install Xcode 16+ or run 'brew install swift-format'"; exit 1; }
	@swift-format lint --strict --parallel --recursive Apps/macOS/Sources Apps/macOS/Tests Packages/TailscreenKit/Sources

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
ICON_SRC := docs/assets/logo.svg
ICON_OUT := Apps/macOS/Resources/Tailscreen.icns
ICONSET  := Apps/macOS/Resources/Tailscreen.iconset

icon: ## Regenerate Tailscreen.icns + in-app PDFs from docs/assets/logo.svg
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

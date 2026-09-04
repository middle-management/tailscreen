.PHONY: help build run clean release install tailscale test test-protocol test-differential test-conformance fuzz-conformance libtailscreen libtailscreen-check test-tsan test-l10n lint lint-baseline lint-tools format format-check print-format-paths-all print-swiftlint-version print-swift-format-version e2e-up e2e-down test-e2e test-e2e-local test-e2e-harness web-viewer web-viewer-bundle test-web-spike icon icon-windows

# Default target: print a one-line summary of every target. Targets are
# self-documented via the `## description` suffix on each rule.
.DEFAULT_GOAL := help

# Lets SwiftPM's systemLibrary targets find their `.pc` files at build time:
#   - libtailscale.pc (TailscaleKit), which resolves the `-L` for
#     libtailscale.a,
#   - libtailscreen.pc (sdk/go), which resolves the `-L`/`-I` for
#     libtailscreen.a (the CTailscreen systemLibrary behind the differential
#     suite), and
#   - opus.pc (OpusKit's COpus wrapper over libopus).
# SwiftPM's own pkg-config resolver does NOT search Homebrew's prefix on
# Apple Silicon, so add `$(brew --prefix)/lib/pkgconfig` explicitly (empty +
# harmless when brew is absent, e.g. Linux, where opus.pc is on the default
# path). Any inherited PKG_CONFIG_PATH is appended so a custom prefix wins.
BREW_PKGCONFIG := $(shell brew --prefix 2>/dev/null)/lib/pkgconfig
export PKG_CONFIG_PATH := $(CURDIR)/Packages/TailscaleKit:$(CURDIR)/sdk/go:$(BREW_PKGCONFIG):$(PKG_CONFIG_PATH)

# ---------------------------------------------------------------------------
# Pinned linter versions — THE source of truth for both developers and CI.
#
# Both are style checks that grade code we did not change, so an unpinned bump
# turns every open PR red on a morning nobody touched the repo. That reasoning
# lives in .github/workflows/build.yml; what lives HERE is the number, because
# the pin has to bind the same way in both places. It used to bind only in CI:
# the workflow asserted its version, `make lint` merely checked that *a*
# swiftlint existed, and Homebrew's latest is whatever it is. A developer whose
# brew swiftlint had drifted got failures on a commit CI passed — the baseline
# records each violation's `reason` string, and a release that rewords one
# unfreezes it. The pin now binds in both, from this one place.
#
# The workflow reads these via `make -s print-swiftlint-version` /
# `print-swift-format-version`, so bumping is still the one-line change it was.
# When bumping SWIFTLINT_VERSION, run `make lint-baseline` in the same commit.
SWIFTLINT_VERSION := 0.65.0
SWIFT_FORMAT_VERSION := 603.0.0

# `make lint-tools` drops the pinned SwiftLint here. Kept repo-local (and
# .gitignore'd) rather than installed globally: the pin is a property of this
# checkout, not of the machine, and a developer working on two repos with two
# pins should not have to choose.
TOOLS_DIR := $(CURDIR)/.tools

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
# names TailscaleKit — hence the full `tailscale` prerequisite.
test-protocol: tailscale ## Build + smoke-test the portable TailscreenKit package
	swift test --package-path Packages/TailscreenKit

# The Swift↔Go differential suite (Packages/TailscreenDifferential): the
# shipping Swift pipeline and the public Go SDK — linked in as
# libtailscreen.a via the CTailscreen systemLibrary — driven with identical
# seeded input, asserting identical output at every step. Its own package,
# not a TailscreenKit test target, because two Go c-archives cannot share
# one binary and TailscreenKit's test executable already links
# libtailscale.a. Reproduces a `linux-differential` CI failure.
test-differential: libtailscreen ## Run the Swift↔Go differential pipeline suite
	swift test --package-path Packages/TailscreenDifferential

# The shared string catalog (Packages/TailscreenL10n). Its suites are the ONLY
# check on the GTK and WinUI apps' user-facing strings: they scan all four
# source trees for `L("…")` keys and fail on any the catalog does not carry, and
# they exercise the `.strings` parser / language resolution / `%@` substitution
# that replaced Apple Foundation's. No dependencies at all, so it runs anywhere
# Swift does; CI's linux-l10n job runs exactly this.
test-l10n: ## Build + test the shared localization catalog package
	swift test --package-path Packages/TailscreenL10n

# The protocol conformance vectors (conformance/), run against the Go
# implementation in conformance/go — which was written from docs/spec.md and
# shares no code with the Swift one. That independence is the whole value: it
# is what tells you the specification is implementable by somebody who only
# read it, rather than merely self-consistent.
#
# The OTHER half runs inside `make test-protocol`: ConformanceVectorTests
# executes the same vectors against the shipping Swift codecs, which is what
# keeps the specification describing Tailscreen rather than an idealized
# cousin of it. Needs Go, which the repo already requires for libtailscale.
# CI's linux-conformance job runs exactly this.
test-conformance: ## Run the protocol conformance vectors (Go runner)
	cd conformance/go && go test ./...

# Coverage-guided fuzzing of the Go SDK's parsers. Their SEED corpus already
# runs on every `go test` (and so on every `make test-conformance`); this
# target is the mutation run, which needs a wall-clock budget and therefore an
# explicit invocation. Go writes any crash to
# sdk/go/tailscreen/testdata/fuzz/<Target>/ — commit it, and it becomes a
# permanent regression case the seed run replays for free.
#
# FUZZTIME is per target, so the whole sweep is FUZZTIME × the target count.
FUZZTIME ?= 30s
fuzz-conformance: ## Fuzz the Go protocol parsers (FUZZTIME=30s per target)
	@cd sdk/go && for target in $$(go test ./tailscreen -list 'Fuzz.*' | grep '^Fuzz'); do \
		echo "== $$target"; \
		go test ./tailscreen -run '^$$' -fuzz "^$$target$$" -fuzztime $(FUZZTIME) || exit 1; \
	done

# libtailscreen.a — the Go wire implementation as a C static library, for
# clients that are not Go. Same mechanism as libtailscale.a one floor down
# (Go compiled with -buildmode=c-archive, consumed through a generated
# header), so the two are built and linked the same way.
#
# Not committed: an archive carries a compiler and a target platform, so it is
# built per machine. Output lands in sdk/go/build/, which .gitignore covers.
#
# -buildvcs=false because the archive does not want a VCS stamp and cannot
# always get one: Go shells out to git to stamp the revision, and inside CI's
# container git refuses the checkout as dubiously-owned and exits 128, which
# fails the build over metadata nothing here reads. Turning it off also makes
# the artifact reproducible from a tarball with no .git at all.
libtailscreen: ## Build sdk/go/build/libtailscreen.{a,h} (C static library)
	@mkdir -p sdk/go/build
	cd sdk/go && go build -buildvcs=false -buildmode=c-archive -o build/libtailscreen.a ./capi
	@echo "sdk/go/build/libtailscreen.a + libtailscreen.h"

# Compiles and runs the C smoke test against the archive. It is the ABI that
# is under test here, not the codecs — those are covered by the vectors, which
# run against the same Go package this archive wraps. What only a C caller can
# check is that the header's signatures match, that the archive links, that a
# returned buffer is really malloc'd memory it can free, and that a rejected
# datagram arrives as a NULL pointer rather than as a crash.
web-viewer: ## Build the browser viewer's wasm (web/viewer/dist) and print its sizes
	cd web/viewer && GOOS=js GOARCH=wasm go build -trimpath -ldflags="-s -w" -o dist/viewer.wasm . \
		&& cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/ \
		&& gzip -9 -k -f dist/viewer.wasm \
		&& (command -v brotli >/dev/null 2>&1 && brotli -f -k -q 11 dist/viewer.wasm || true) \
		&& ls -l dist/viewer.wasm dist/viewer.wasm.gz dist/viewer.wasm.br 2>/dev/null
	python3 web/viewer/tools/export_strings.py

web-viewer-bundle: web-viewer ## One self-contained HTML file of the browser viewer (web/viewer/dist/tailscreen-viewer.html)
	python3 web/viewer/tools/bundle.py

test-web-spike: web-viewer ## Browser↔sharer end-to-end: wire + audio checks, then localderp + Xvfb + sharer --link + Chrome (Linux)
	node web/viewer/e2e/wire.test.mjs
	NODE_PATH="$$(npm root -g)" node web/viewer/e2e/audio.test.mjs
	cd web/viewer && go build -o dist/localderp ./cmd/localderp
	cd Packages/TailscreenLinuxBackends && PKG_CONFIG_PATH=$(CURDIR)/Packages/TailscaleKit swift build --product tailscreen-sharer-linux
	NODE_PATH="$$(npm root -g)" node web/viewer/e2e/spike.mjs

libtailscreen-check: libtailscreen ## Build + run the C smoke test against the archive
	cc -Wall -Wextra -Isdk/go/build sdk/go/ctest/smoke.c sdk/go/build/libtailscreen.a \
		-lpthread -o sdk/go/build/smoke
	./sdk/go/build/smoke

# Thread sanitizer build of the test suite. Catches data races on locks,
# double-resumed continuations, callback ordering bugs that compile fine
# under Swift 6 strict concurrency. Slower (~3x), so kept off `make test`.
test-tsan: tailscale ## Run tests under ThreadSanitizer
	cd Apps/macOS && swift test --sanitize=thread

# Assert that the SwiftLint about to run is the pinned one (SWIFTLINT_VERSION
# at the top of this file). CI asserts the same thing for the same reason: a
# pin that silently isn't in effect is precisely the failure the pin exists to
# prevent, and it surfaces as a mystery violation rather than as "wrong tool".
#
# The baseline is what makes this load-bearing rather than pedantic. It freezes
# each violation by, among other fields, its `reason` STRING — so a release
# that merely rewords one unfreezes that violation, and an unpinned local run
# reports failures on a commit CI passed. `redundant_nil_coalescing` is a live
# example: 0.63 and 0.65 word it differently.
#
# TAILSCREEN_SWIFTLINT_ANY=1 overrides, for the one case the assertion would
# otherwise block: bumping the pin, where the new version has to run against
# the old baseline once to produce the refreshed one.
#
# Resolved in the SHELL, not by `$(wildcard)`: make caches directory listings
# for the length of a run, so a make-level test for .tools/swiftlint would read
# stale in exactly the invocation that most needs it right — `make lint-tools
# lint`, where the binary appears mid-run.
define require-pinned-swiftlint
@set -e; \
	SWIFTLINT="$(TOOLS_DIR)/swiftlint"; \
	[ -x "$$SWIFTLINT" ] || SWIFTLINT=swiftlint; \
	command -v "$$SWIFTLINT" >/dev/null 2>&1 || { \
		echo "swiftlint missing — 'make lint-tools' fetches the pinned $(SWIFTLINT_VERSION)"; exit 1; }; \
	got="$$($$SWIFTLINT version)"; \
	if [ "$$got" != "$(SWIFTLINT_VERSION)" ] && [ -z "$$TAILSCREEN_SWIFTLINT_ANY" ]; then \
		echo "SwiftLint $$got is not the pinned $(SWIFTLINT_VERSION) (from $$(command -v $$SWIFTLINT))"; \
		echo "The baseline is version-specific, so this run would report violations CI does not have."; \
		echo "  make lint-tools             fetch the pinned binary into .tools/"; \
		echo "  TAILSCREEN_SWIFTLINT_ANY=1  run anyway (only when bumping the pin)"; \
		exit 1; \
	fi; \
	$(1)
endef

# SwiftLint over the trees listed in `.swiftlint.yml`. `make lint-tools` gets
# you the pinned binary; a `brew install swiftlint` is whatever brew ships
# today and will be rejected once it drifts.
# Existing violations are frozen in .swiftlint-baseline.json; only NEW
# warnings/errors fail the run. Refresh baseline via `make lint-baseline`
# after a real cleanup pass.
lint: ## Run SwiftLint (baseline-gated; new violations fail)
	$(call require-pinned-swiftlint,\
		"$$SWIFTLINT" lint --baseline .swiftlint-baseline.json --strict --quiet)

# Fetch the pinned SwiftLint into .tools/, which `lint` and `lint-baseline`
# then prefer over anything on PATH. This is the same artifact CI installs —
# each SwiftLint release publishes a prebuilt universal macOS binary as
# portable_swiftlint.zip — so "passes locally" and "passes in CI" become the
# same statement.
#
# macOS only, because that artifact is: the lint job runs on macos-latest, and
# SwiftLint publishes no equivalent portable Linux binary. A Linux developer
# gets told what to do rather than a confused unzip error.
lint-tools: ## Fetch the pinned SwiftLint into .tools/
	@test "$$(uname -s)" = "Darwin" || { \
		echo "portable_swiftlint.zip is a macOS binary; on Linux install SwiftLint $(SWIFTLINT_VERSION) yourself"; \
		echo "(or lean on CI's lint job, which is the gate either way)"; exit 1; }
	@mkdir -p $(TOOLS_DIR)
	@echo "Fetching SwiftLint $(SWIFTLINT_VERSION)…"
	@curl -fsSL "https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip" \
		-o "$(TOOLS_DIR)/swiftlint.zip"
	@unzip -q -o "$(TOOLS_DIR)/swiftlint.zip" -d "$(TOOLS_DIR)/unpack"
	@mv -f "$(TOOLS_DIR)/unpack/swiftlint" "$(TOOLS_DIR)/swiftlint"
	@chmod +x "$(TOOLS_DIR)/swiftlint"
	@rm -rf "$(TOOLS_DIR)/swiftlint.zip" "$(TOOLS_DIR)/unpack"
	@echo "$(TOOLS_DIR)/swiftlint is now $$($(TOOLS_DIR)/swiftlint version)"

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
	@command -v python3 >/dev/null 2>&1 || { echo "python3 missing — needed to normalize the baseline"; exit 1; }
	@rm -f .swiftlint-baseline.json.new
	$(call require-pinned-swiftlint,\
		"$$SWIFTLINT" lint --write-baseline .swiftlint-baseline.json.new --quiet || true)
	@test -s .swiftlint-baseline.json.new || { echo "swiftlint wrote no baseline"; exit 1; }
	@python3 scripts/normalize-lint-baseline.py \
		.swiftlint-baseline.json.new .swiftlint-baseline.json "$(CURDIR)"
	@rm -f .swiftlint-baseline.json.new
	@echo "Wrote .swiftlint-baseline.json"

# Apple's swift-format ships with the Swift toolchain on macOS (Xcode 16+).
# `format` rewrites files in place; `format-check` is the lint-only mode
# used by CI. Config lives in `.swift-format` at the repo root.

# Every tree in the repo that carries Swift we own. This IS what `format` and
# `format-check` run over — the repo-wide sweep that made every tree conform
# has landed, and the `format` job is a required check.
#
# What is deliberately NOT in the list:
#   • C/C++/ObjC shims (Packages/*/Sources/C*/**.c,.h and friends) — excluded
#     by construction, not by name: swift-format only touches *.swift, so
#     listing a Sources tree that also holds a shim target is safe.
#   • Packages/TailscaleKit/Sources — Sources/TailscaleKit is a SYMLINK into
#     the libtailscale submodule. Formatting it would rewrite upstream
#     BSD-licensed files through the symlink, dirtying the fork submodule
#     with unreviewed churn. (Its sibling
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

# Every tree swift-format owns. Was five trees for as long as the check was
# advisory; the sweep that made the rest conform is what let it become the
# default — and the required check. FORMAT_PATHS_ALL above is the definition;
# this alias is what `format` and `format-check` actually read, kept so a
# future carve-out has somewhere to go that is not the definition itself.
# `:=` is immediate expansion, so this line MUST stay BELOW the definition
# above. Placed before it, it expands to the empty string and `format-check`
# passes by checking nothing at all.
FORMAT_PATHS := $(FORMAT_PATHS_ALL)

print-format-paths-all: ## Print FORMAT_PATHS_ALL (the target-state format tree list)
	@echo '$(FORMAT_PATHS_ALL)'

print-swiftlint-version: ## Print the pinned SwiftLint version (CI reads this)
	@echo '$(SWIFTLINT_VERSION)'

print-swift-format-version: ## Print the pinned swift-format version (CI reads this)
	@echo '$(SWIFT_FORMAT_VERSION)'

# swift-format's pin is NOTED, not asserted — deliberately weaker than
# SwiftLint's, and weaker for a reason that is a property of the tool rather
# than of how much we care. There is no prebuilt swift-format release artifact
# (the swiftlang/swift-format releases are source tags), so CI builds the
# pinned tag from source and can only LOG what it got: a source build reports
# the swift-syntax version, which has not always matched the tag. An assertion
# whose expected value the pinned build itself may not print would fail on the
# pinned build. So: a version mismatch is reported as the likely explanation if
# the run then disagrees with CI, and the run proceeds.
define note-swift-format-version
@command -v swift-format >/dev/null 2>&1 || { \
		echo "swift-format missing — install Xcode 16+ or run 'brew install swift-format'"; exit 1; }
@got="$$(swift-format --version 2>/dev/null)"; \
	case "$$got" in \
		$(SWIFT_FORMAT_VERSION)*) : ;; \
		*) echo "note: swift-format $$got is not the pinned $(SWIFT_FORMAT_VERSION)."; \
		   echo "      If this disagrees with CI, suspect the version before the diff —"; \
		   echo "      swift-format's job is rewriting source, so a retuned heuristic"; \
		   echo "      reformats files nobody touched." ;; \
	esac
endef

format: ## Run swift-format in-place over every tree we own
	$(note-swift-format-version)
	@swift-format format --in-place --parallel --recursive $(FORMAT_PATHS)

format-check: ## Run swift-format in lint mode (no changes); CI uses this
	$(note-swift-format-version)
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
# by the README, docs, and in-app PDFs. The tile outline is Apple's
# continuous corner, not an `rx` rounded rect — regenerate that path with
# scripts/squircle.py if the tile geometry ever changes.
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

# Regenerate the Windows MSIX logo assets from the same source SVG. Sizes are
# the ones AppxManifest.xml names (scale-100 only — the manifest references the
# bare filenames). The wide tile is the square icon centered on a transparent
# 310x150 page rather than a stretch: rsvg-convert's -w/-h would distort it.
WIN_ASSETS := Apps/windows/packaging/Assets

icon-windows: ## Regenerate the Windows MSIX logo PNGs from docs/assets/app-icon.svg
	@command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert missing — brew install librsvg / apt install librsvg2-bin"; exit 1; }
	@rsvg-convert -w 44  -h 44  "$(ICON_SRC)" -o "$(WIN_ASSETS)/Square44x44Logo.png"
	@rsvg-convert -w 50  -h 50  "$(ICON_SRC)" -o "$(WIN_ASSETS)/StoreLogo.png"
	@rsvg-convert -w 150 -h 150 "$(ICON_SRC)" -o "$(WIN_ASSETS)/Square150x150Logo.png"
	@rsvg-convert -w 310 -h 310 "$(ICON_SRC)" -o "$(WIN_ASSETS)/Square310x310Logo.png"
	@rsvg-convert -w 150 -h 150 --page-width 310 --page-height 150 --left 80 "$(ICON_SRC)" -o "$(WIN_ASSETS)/Wide310x150Logo.png"
	@echo "Wrote $(WIN_ASSETS)/{Square44x44Logo,StoreLogo,Square150x150Logo,Square310x310Logo,Wide310x150Logo}.png"

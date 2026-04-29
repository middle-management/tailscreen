.PHONY: build run clean release install tailscale test test-tsan lint lint-baseline e2e-up e2e-down test-e2e icon

# Lets SwiftPM's systemLibrary target find libtailscale.pc at build time,
# which in turn resolves the `-L` flag for libtailscale.a.
export PKG_CONFIG_PATH := $(CURDIR)/TailscaleKitPackage

# Build TailscaleKit C library if needed
tailscale:
	@cd TailscaleKitPackage && $(MAKE)

# Build with TailscaleKit dependency
build: tailscale
	swift build

run: tailscale
	swift run

test: tailscale
	swift test

# Thread sanitizer build of the test suite. Catches data races on locks,
# double-resumed continuations, callback ordering bugs that compile fine
# under Swift 6 strict concurrency. Slower (~3x), so kept off `make test`.
test-tsan: tailscale
	swift test -Xswiftc -sanitize=thread

# SwiftLint over Sources/Tests/Examples. Install once: `brew install swiftlint`.
# Existing violations are frozen in .swiftlint-baseline.json; only NEW
# warnings/errors fail the run. Refresh baseline via `make lint-baseline`
# after a real cleanup pass.
lint:
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint missing — brew install swiftlint"; exit 1; }
	@swiftlint lint --baseline .swiftlint-baseline.json --strict --quiet

lint-baseline:
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint missing — brew install swiftlint"; exit 1; }
	@swiftlint lint --write-baseline .swiftlint-baseline.json --quiet
	@echo "Wrote .swiftlint-baseline.json"

release: tailscale
	swift build -c release
	@echo "Binary available at: .build/release/Tailscreen"

clean:
	swift package clean
	rm -rf .build
	@cd TailscaleKitPackage && $(MAKE) clean

install: release
	@mkdir -p ~/bin
	@cp .build/release/Tailscreen ~/bin/
	@echo "Installed to ~/bin/Tailscreen"

# Bring up a local headscale control server for integration testing.
# Prints `export ...` lines on stdout; run via `eval "$$(make e2e-up)"`.
e2e-up:
	@./scripts/e2e-up.sh

e2e-down:
	@./scripts/e2e-down.sh

# One-shot: spin headscale, run the connectivity test, tear down.
test-e2e: tailscale
	@./scripts/e2e-test.sh

# Regenerate the macOS .icns app icon from the source SVG. Requires
# librsvg (`brew install librsvg`) and the system iconutil.
ICON_SRC := docs/assets/logo.svg
ICON_OUT := Resources/Tailscreen.icns
ICONSET  := Resources/Tailscreen.iconset

icon:
	@command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert missing — brew install librsvg"; exit 1; }
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
	@rsvg-convert -f pdf Sources/Resources/MenubarIcon.svg    -o Sources/Resources/MenubarIcon.pdf
	@rsvg-convert -f pdf Sources/Resources/MenubarSharing.svg -o Sources/Resources/MenubarSharing.pdf
	@rsvg-convert -f pdf Sources/Resources/MenubarViewing.svg -o Sources/Resources/MenubarViewing.pdf
	@rsvg-convert -f pdf docs/assets/logo.svg -o Sources/Resources/WelcomeIcon.pdf
	@echo "Wrote Sources/Resources/{MenubarIcon,MenubarSharing,MenubarViewing,WelcomeIcon}.pdf"

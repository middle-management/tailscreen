.PHONY: build run clean release install tailscale test e2e-up e2e-down test-e2e

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

release: tailscale
	swift build -c release
	@echo "Binary available at: .build/release/Cuple"

clean:
	swift package clean
	rm -rf .build
	@cd TailscaleKitPackage && $(MAKE) clean

install: release
	@mkdir -p ~/bin
	@cp .build/release/Cuple ~/bin/
	@echo "Installed to ~/bin/Cuple"

# Bring up a local headscale control server for integration testing.
# Prints `export ...` lines on stdout; run via `eval "$$(make e2e-up)"`.
e2e-up:
	@./scripts/e2e-up.sh

e2e-down:
	@./scripts/e2e-down.sh

# One-shot: spin headscale, run the connectivity test, tear down.
test-e2e: tailscale
	@./scripts/e2e-test.sh

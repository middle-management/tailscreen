.PHONY: build run clean release install tailscale test

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

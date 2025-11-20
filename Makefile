.PHONY: build run clean release

build:
	swift build

run:
	swift run

release:
	swift build -c release
	@echo "Binary available at: .build/release/Cuple"

clean:
	swift package clean
	rm -rf .build

install: release
	@mkdir -p ~/bin
	@cp .build/release/Cuple ~/bin/
	@echo "Installed to ~/bin/Cuple"

# Makefile for TailscaleKit Package
#
# The submodule is our fork (middle-management/libtailscale, branch
# tailscreen-main), which carries the former Patches/ series as ordinary
# commits — there is no patch step anymore. To change the wrapped sources,
# commit in the submodule on that branch, push to the fork, and bump the
# submodule pointer here.

.PHONY: all clean help

# Path to the C library
LIB := lib/libtailscale.a
UPSTREAM_LIB := upstream/libtailscale/libtailscale.a

all: $(LIB)

# Build the C library if it doesn't exist
$(LIB): $(UPSTREAM_LIB)
	@echo "✅ C library ready at $(LIB)"

$(UPSTREAM_LIB):
	@if [ ! -f upstream/libtailscale/Makefile ]; then \
		echo "❌ Submodule not initialized"; \
		echo "   Run: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@echo "🔨 Building libtailscale C library..."
	@cd upstream/libtailscale && $(MAKE) c-archive
	@echo "✅ libtailscale.a built successfully"

clean:
	@echo "🧹 Cleaning build artifacts..."
	@cd upstream/libtailscale && $(MAKE) clean 2>/dev/null || true
	@echo "✅ Clean complete"

help:
	@echo "TailscaleKit Package Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all              - Build the C library (default)"
	@echo "  clean            - Clean build artifacts"
	@echo "  help             - Show this help message"
	@echo ""
	@echo "The C library will be automatically built when needed."
	@echo "Sources are symlinked from upstream/libtailscale/swift/TailscaleKit/"
	@echo "(the submodule is our fork; local changes are commits there, not patches)."

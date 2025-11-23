# Makefile for TailscaleKit Package

.PHONY: all clean help apply-patches unapply-patches

# Path to the C library
LIB := lib/libtailscale.a
UPSTREAM_LIB := upstream/libtailscale/libtailscale.a
PATCH_MARKER := .patches-applied
PATCHES_DIR := Patches

all: $(LIB)

# Build the C library if it doesn't exist
$(LIB): $(UPSTREAM_LIB)
	@echo "✅ C library ready at $(LIB)"

# Apply patches before building
$(UPSTREAM_LIB): $(PATCH_MARKER)
	@echo "🔨 Building libtailscale C library..."
	@cd upstream/libtailscale && $(MAKE) c-archive
	@echo "✅ libtailscale.a built successfully"

# Apply patches to upstream sources
$(PATCH_MARKER):
	@if [ ! -f upstream/libtailscale/Makefile ]; then \
		echo "❌ Submodule not initialized"; \
		echo "   Run: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@echo "🔧 Applying patches to upstream Swift sources..."
	@for patch in $(PATCHES_DIR)/*.patch; do \
		if [ -f "$$patch" ]; then \
			echo "   Applying $$(basename $$patch)..."; \
			patch -p1 -N -r - < "$$patch" || true; \
		fi; \
	done
	@touch $(PATCH_MARKER)
	@echo "✅ Patches applied"

apply-patches: $(PATCH_MARKER)

unapply-patches:
	@if [ -f $(PATCH_MARKER) ]; then \
		echo "🔧 Reverting patches..."; \
		for patch in $(PATCHES_DIR)/*.patch; do \
			if [ -f "$$patch" ]; then \
				echo "   Reverting $$(basename $$patch)..."; \
				patch -p1 -R -r - < "$$patch" || true; \
			fi; \
		done; \
		rm -f $(PATCH_MARKER); \
		echo "✅ Patches reverted"; \
	else \
		echo "ℹ️  No patches to revert"; \
	fi

clean: unapply-patches
	@echo "🧹 Cleaning build artifacts..."
	@cd upstream/libtailscale && $(MAKE) clean 2>/dev/null || true
	@echo "✅ Clean complete"

help:
	@echo "TailscaleKit Package Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all              - Build the C library (default)"
	@echo "  apply-patches    - Apply patches to upstream sources"
	@echo "  unapply-patches  - Revert patches from upstream sources"
	@echo "  clean            - Clean build artifacts and revert patches"
	@echo "  help             - Show this help message"
	@echo ""
	@echo "The C library will be automatically built when needed."
	@echo "Sources are symlinked from upstream/libtailscale/swift/TailscaleKit/"
	@echo "Patches in $(PATCHES_DIR)/ are automatically applied before building."


# Makefile for TailscaleKit Package
#
# The submodule is our fork (middle-management/libtailscale, branch
# tailscreen-main), which carries the former Patches/ series as ordinary
# commits — there is no patch step anymore. To change the wrapped sources,
# commit in the submodule on that branch, push to the fork, and bump the
# submodule pointer here.

.PHONY: all build-lib clean help

# Path to the C library. lib/libtailscale.a is a TRACKED SYMLINK into the
# submodule (SwiftPM's -L flag and libtailscale.pc both point at lib/);
# the archive itself is built in the submodule.
LIB := lib/libtailscale.a
UPSTREAM_LIB := upstream/libtailscale/libtailscale.a

# Rebuild whenever the submodule checkout moves. The archive must match the
# submodule commit: switching to a branch whose pointer adds exports (the
# fork carries our changes as commits now) while an old archive sits around
# otherwise links against stale code — undefined-symbol errors at best,
# silently old behavior at worst. The stamp carries the commit hash, so a
# pointer bump invalidates it and an unchanged one costs nothing.
SUBMODULE_HEAD := $(shell git -C upstream/libtailscale rev-parse HEAD 2>/dev/null || echo unknown)
STAMP := .lib-built-$(SUBMODULE_HEAD)

all: build-lib

# Phony on purpose: the recipe's own checks make an up-to-date run a no-op,
# and expressing "archive exists AND matches the current submodule commit
# AND the symlink resolves" as file dependencies is exactly the shape make
# gets subtly wrong (a satisfied stamp used to shadow a deleted archive).
build-lib:
	@if [ ! -f upstream/libtailscale/Makefile ]; then \
		echo "❌ Submodule not initialized"; \
		echo "   Run: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@if [ ! -f $(UPSTREAM_LIB) ] || [ ! -f $(STAMP) ]; then \
		echo "🔨 Building libtailscale C library ($(SUBMODULE_HEAD))..."; \
		(cd upstream/libtailscale && $(MAKE) c-archive) || exit 1; \
		rm -f .lib-built-*; \
		touch $(STAMP); \
		echo "✅ libtailscale.a built successfully"; \
	fi
	@# Recreate the lib/ symlink if a checkout lost it (a submodule-URL
	@# switch or an archive-extracted tree can drop it) — without it the
	@# linker's -L Packages/TailscaleKit/lib resolves nothing and the build
	@# fails with "library 'tailscale' not found" even though the archive
	@# just built.
	@if [ ! -e $(LIB) ]; then \
		mkdir -p lib && ln -sf ../$(UPSTREAM_LIB) $(LIB); \
		echo "🔗 Restored lib/libtailscale.a symlink"; \
	fi
	@echo "✅ C library ready at $(LIB)"

clean:
	@echo "🧹 Cleaning build artifacts..."
	@cd upstream/libtailscale && $(MAKE) clean 2>/dev/null || true
	@rm -f .lib-built-*
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

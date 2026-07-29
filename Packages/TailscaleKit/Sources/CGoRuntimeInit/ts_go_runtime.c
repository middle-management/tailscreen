#include "include/ts_go_runtime.h"

/*
 * Starts the Go runtime inside libtailscale.a on Windows, because nothing
 * else does.
 *
 * THE BUG THIS FIXES. The Windows app froze the moment it signed in, with two
 * lines on stderr and nothing after:
 *
 *     [tsnet] prepare: creating state dir …
 *     [tsnet] prepare: creating tsnet node … (ephemeral=true)
 *
 * The next statement in TailscaleNode.init is a log line, and exactly one
 * call sits between them: tailscale_new(), the first call into the Go
 * archive. GODEBUG=inittrace=1 printed nothing at all — not a slow package,
 * but no Go runtime.
 *
 * WHY. A Go c-archive does not run its own startup. It asks the C runtime to
 * call `_rt0_amd64_windows_lib`, which spawns the thread that initialises the
 * runtime, and until that happens every cgo entry point blocks in
 * `_cgo_wait_runtime_init_done` — forever, with no timeout and no diagnostic.
 * From Go's own rt0_windows_amd64.s:
 *
 *     // When building with -buildmode=(c-shared or c-archive), this
 *     // symbol is called. … For static libraries it is called when the
 *     // final executable starts, during the C runtime initialization phase.
 *
 * The question is HOW it asks, and the answer is the whole problem.
 * cmd/link/internal/ld/pe.go writes that pointer into a section called
 * `.ctors`:
 *
 *     // addInitArray adds .ctors COFF section to the file f.
 *
 * `.ctors` is the GNU convention, walked by MinGW's startup objects. Go's
 * Windows support is built around a MinGW toolchain, so under gcc this works
 * and always has. MSVC's C runtime walks `.CRT$XCA` … `.CRT$XCZ` and has
 * never looked at `.ctors`. Swift on Windows is an MSVC toolchain and links
 * with lld-link in MSVC mode, so the section is dutifully carried into the
 * executable and never read. The initialiser is present, correct, and dead.
 *
 * Nothing in the build can notice this. The archive links, every symbol
 * resolves, the app starts, the UI comes up — and the first tsnet call parks
 * a thread forever.
 *
 * THE FIX. Call the entry point ourselves, twice over:
 *
 *   1. Through `.CRT$XCU`, which is MSVC's spelling of the same idea. This
 *      reproduces Go's documented timing exactly — during CRT init, before
 *      main — so the runtime initialises concurrently with the rest of
 *      startup instead of stalling the first caller.
 *
 *   2. Explicitly, from TailscaleNode.init before tailscale_new(). This is
 *      the one that cannot fail quietly. A `.CRT$XCU` entry only runs if this
 *      object file was pulled out of its static library, and an object is
 *      pulled only when something references a symbol in it — which for a
 *      file whose entire contents are an initialiser is not guaranteed. The
 *      explicit call is that reference, and it also guarantees the runtime is
 *      starting no matter what the linker did with the section.
 *
 * Both routes hit an interlocked guard, so the entry point runs exactly once
 * however many times this is called and from however many threads.
 *
 * `_cgo_sys_thread_create`, which the entry point dereferences, is
 * link-time-initialised data (runtime/cgo/callbacks.go), not something a
 * previous init phase has to have set up — which is what makes calling this
 * from main as legitimate as calling it from CRT init.
 */

#if defined(_WIN32)

#include <windows.h>

/*
 * The entry symbol is per-architecture: cmd/link derives it as
 * `_rt0_<GOARCH>_<GOOS>_lib`. Only the architectures we actually build the
 * archive for are named — an unhandled one leaves TS_GO_RT0 undefined and
 * this becomes a no-op, which would resurrect the freeze. So it is a hard
 * compile error instead. A wrong guess here is a hang; a missing case should
 * be a build failure.
 */
#if defined(_M_X64) || defined(__x86_64__)
extern void _rt0_amd64_windows_lib(void);
#define TS_GO_RT0 _rt0_amd64_windows_lib
#elif defined(_M_ARM64) || defined(__aarch64__)
extern void _rt0_arm64_windows_lib(void);
#define TS_GO_RT0 _rt0_arm64_windows_lib
#else
#error "unknown Windows architecture: name its Go c-archive entry symbol"
#endif

static LONG ts_go_runtime_started = 0;

void ts_go_runtime_start(void) {
    /* Compare-exchange, not a plain flag: the CRT initialiser and an early
     * caller can genuinely race, and starting the Go runtime twice would
     * create two runtimes in one process. */
    if (InterlockedCompareExchange(&ts_go_runtime_started, 1, 0) == 0) {
        TS_GO_RT0();
    }
}

static void ts_go_runtime_crt_init(void) { ts_go_runtime_start(); }

/* MSVC's initialiser table. `used` keeps it through dead-stripping, which
 * would otherwise remove a pointer nothing appears to read. */
__attribute__((section(".CRT$XCU"), used)) static void (*ts_go_runtime_crt_entry)(void) =
    ts_go_runtime_crt_init;

#else

/*
 * Everywhere else the platform starts the Go runtime itself: Mach-O runs the
 * archive's initialiser out of __DATA,__mod_init_func and ELF out of
 * .init_array, both of which the system loader walks. Defined as an empty
 * function rather than compiled away so callers need no per-platform
 * conditional.
 */
void ts_go_runtime_start(void) {}

#endif

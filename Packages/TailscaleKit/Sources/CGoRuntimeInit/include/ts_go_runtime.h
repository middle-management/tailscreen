#ifndef TS_GO_RUNTIME_H
#define TS_GO_RUNTIME_H

/// Start the Go runtime that libtailscale.a carries, if this platform does
/// not start it on its own.
///
/// Idempotent and cheap after the first call, so callers do not have to
/// track whether it already happened. On every platform but Windows it is an
/// empty function — see ts_go_runtime.c for why Windows is different.
///
/// Call this before the first call into libtailscale. It does not wait: the
/// runtime initialises on its own thread, and the first cgo call blocks until
/// that finishes, which is the sequencing Go already implements.
void ts_go_runtime_start(void);

#endif /* TS_GO_RUNTIME_H */

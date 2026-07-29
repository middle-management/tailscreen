// ts_wasapi.h — a flat C surface over WASAPI shared-mode rendering.
//
// WASAPI is COM: IMMDeviceEnumerator → IMMDevice → IAudioClient →
// IAudioRenderClient, four interfaces and a mix-format negotiation before a
// single sample plays. Swift can call COM, but only through the vtable by hand,
// and doing that across a language boundary buys nothing — so the boilerplate
// lives here and Swift sees three functions, the same division ALSAKit and
// X11CaptureKit use for libasound and libxcb.
//
// Everything here is `#ifdef _WIN32`; on other platforms the translation unit is
// empty so the package still builds (and its Swift wrapper compiles to an empty
// module) wherever the rest of the repo is built.

#ifndef TS_WASAPI_H
#define TS_WASAPI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque render session: the audio client, its render service, and the format
/// the device negotiated.
typedef struct ts_wasapi ts_wasapi;

/// Error codes. Negative values are ours; a positive value is a raw HRESULT
/// cast to int32_t, so an unexpected COM failure keeps its identity all the way
/// to the log line instead of collapsing into "audio failed".
enum {
    TS_WASAPI_OK = 0,
    /// The endpoint's shared-mode mix format is not 32-bit float. Writing our
    /// float samples into, say, a 16-bit PCM buffer would emit noise at full
    /// scale, so this refuses rather than converting silently.
    TS_WASAPI_ERR_FORMAT = -1,
    /// A null handle or a zero-frame write.
    TS_WASAPI_ERR_ARGUMENT = -2,
    /// The device stopped accepting data for longer than the write timeout —
    /// unplugged, or a driver wedge.
    TS_WASAPI_ERR_TIMEOUT = -3,
};

/// Open the default render endpoint in shared mode and start it.
///
/// MUST be called on the same thread that will call `ts_wasapi_write`: COM
/// apartment state is per-thread, and this initialises the calling thread's
/// apartment. `ThreadedAudioSink` gives us that for free — every `play` runs on
/// its single drain thread — which is why the Swift wrapper opens lazily on the
/// first write rather than in its initialiser.
///
/// - out: receives the session on success, untouched on failure.
/// - sample_rate, channels: receive the negotiated device format. The caller
///   converts its mono 48 kHz PCM to match; shared mode does not accept
///   anything else.
/// - Returns TS_WASAPI_OK, one of the TS_WASAPI_ERR_* codes, or an HRESULT.
int32_t ts_wasapi_open(ts_wasapi **out, uint32_t *sample_rate, uint32_t *channels);

/// Write interleaved float frames, blocking until they are all queued.
///
/// - interleaved: `frames * channels` floats in [-1, 1].
/// - Returns TS_WASAPI_OK, one of the TS_WASAPI_ERR_* codes, or an HRESULT.
int32_t ts_wasapi_write(ts_wasapi *handle, const float *interleaved, uint32_t frames);

/// Stop and release the session. Safe on NULL; safe to call twice.
void ts_wasapi_close(ts_wasapi *handle);

#ifdef __cplusplus
}
#endif

#endif  // TS_WASAPI_H

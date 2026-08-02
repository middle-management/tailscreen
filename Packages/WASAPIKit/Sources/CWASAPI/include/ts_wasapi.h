// ts_wasapi.h — a flat C surface over WASAPI shared-mode rendering and capture.
//
// WASAPI is COM: IMMDeviceEnumerator → IMMDevice → IAudioClient →
// IAudioRenderClient, four interfaces and a mix-format negotiation before a
// single sample plays. Swift can call COM, but only through the vtable by hand,
// and doing that across a language boundary buys nothing — so the boilerplate
// lives here and Swift sees six functions, the same division ALSAKit and
// X11CaptureKit use for libasound and libxcb.
//
// Capture is the same four-interface climb with `IAudioCaptureClient` in place
// of `IAudioRenderClient` and `eCapture` in place of `eRender`. It shares this
// translation unit rather than getting its own precisely because of that: the
// COM-apartment dance, the float32 mix-format check and the endpoint walk are
// one implementation each, and two copies of them would be two things to keep
// in step.
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
    /// A capture read was handed a buffer too small to hold even one packet.
    /// WASAPI hands capture data out whole — `ReleaseBuffer` must acknowledge
    /// exactly the frame count `GetBuffer` reported — so a short buffer cannot
    /// be partially filled and would otherwise return zero frames forever while
    /// the endpoint overran behind it. Failing loudly beats recording silence.
    TS_WASAPI_ERR_BUFFER_TOO_SMALL = -4,
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

/// Opaque capture session: the audio client, its capture service, and the
/// format the device negotiated.
typedef struct ts_wasapi_capture ts_wasapi_capture;

/// Open the default capture endpoint (the microphone Windows itself would use)
/// in shared mode and start it.
///
/// Same thread rule as `ts_wasapi_open`, for the same reason: this initialises
/// the calling thread's COM apartment, so whichever thread opens must be the
/// one that calls `ts_wasapi_capture_read`.
///
/// - out: receives the session on success, untouched on failure.
/// - sample_rate, channels: receive the negotiated device format. This is NOT
///   converted for you — the endpoint's own rate and channel count come back
///   and the caller adapts, exactly as on the render side.
/// - buffer_frames: the engine buffer's size in frames. It is the largest a
///   single capture packet can be, so a read buffer of at least this many
///   frames (× channels) can never hit TS_WASAPI_ERR_BUFFER_TOO_SMALL.
/// - Returns TS_WASAPI_OK, one of the TS_WASAPI_ERR_* codes, or an HRESULT.
///   E_ACCESSDENIED here is the ordinary Windows microphone privacy setting,
///   not a bug.
int32_t ts_wasapi_capture_open(ts_wasapi_capture **out, uint32_t *sample_rate, uint32_t *channels,
                               uint32_t *buffer_frames);

/// Drain whatever the endpoint has queued right now into `interleaved`.
///
/// Deliberately NON-blocking, which is the one place this diverges in shape
/// from `ts_wasapi_write`. A microphone produces samples on its own schedule;
/// blocking until some caller-chosen frame count arrived would make this
/// function decide the capture cadence, and the caller — which has to bin the
/// audio into 20 ms Opus frames regardless — already owns a clock. So
/// `*frames_read == 0` is the ordinary "nothing yet" answer, not an error.
///
/// - interleaved: receives `frames_read * channels` floats.
/// - capacity_frames: how many FRAMES (not floats) `interleaved` can hold. Only
///   whole packets that fit are consumed; a packet that does not fit is left
///   queued for the next call, and one that cannot fit in an empty buffer is
///   TS_WASAPI_ERR_BUFFER_TOO_SMALL.
/// - frames_read: receives the frame count actually written.
/// - discontinuity: optional (may be NULL). Set to 1 when any packet in this
///   read was flagged as following a glitch — the caller's resampler wants to
///   drop the sample it was carrying across the gap rather than interpolate
///   over a hole. Set to 0 otherwise; never left untouched.
/// - Returns TS_WASAPI_OK, one of the TS_WASAPI_ERR_* codes, or an HRESULT.
int32_t ts_wasapi_capture_read(ts_wasapi_capture *handle, float *interleaved,
                               uint32_t capacity_frames, uint32_t *frames_read,
                               int32_t *discontinuity);

/// Stop and release the capture session. Safe on NULL; safe to call twice.
void ts_wasapi_capture_close(ts_wasapi_capture *handle);

#ifdef __cplusplus
}
#endif

#endif  // TS_WASAPI_H

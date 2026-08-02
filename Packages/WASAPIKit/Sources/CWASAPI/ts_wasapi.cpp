#include "include/ts_wasapi.h"

#ifdef _WIN32

// C++ rather than C, for exactly one reason: `__uuidof`.
//
// The first version of this file was C, and it linked against `uuid.lib` for
// CLSID_MMDeviceEnumerator and the three interface IIDs. That library does not
// carry them — the MMDevice GUIDs live in MIDL-generated `_i.c` files that no
// SDK import library includes — so the app failed at link with four undefined
// symbols. The usual C workaround is to type the GUIDs out by hand, which
// trades a link error the build catches for an E_NOINTERFACE at run time that
// nothing here can.
//
// In C++ the SDK headers annotate each interface and coclass with
// `DECLSPEC_UUID`, so `__uuidof(IAudioClient)` reads the value straight out of
// the declaration at compile time. No hardcoded bytes, no extra library, and a
// wrong name is a compile error rather than a silent mismatch. The file stays
// `extern "C"` at its boundary, so Swift still imports a plain C header.

// NO C++ standard library headers here, and not merely as minimalism.
//
// MSVC's STL hard-asserts the compiler version it was built for: including
// <cstdlib> against MSVC 14.51 with the clang 19 that Swift 6.1.3 ships fails
// with `error STL1000: Unexpected compiler version, expected Clang 20 or
// newer`. That combination is whatever the runner image happens to pair, so it
// is not ours to fix and not ours to depend on. There is an escape hatch
// (_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH) but it opts into a combination
// Microsoft says is unsupported, and this file needs three functions:
// allocation, release and a copy. Win32 has all three, from <windows.h>, and
// C++ here buys exactly one thing — `__uuidof` — which costs no library at all.
#define WIN32_LEAN_AND_MEAN

#include <windows.h>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>

// 100 ms of engine buffer, in 100-nanosecond units. On the render side, large
// enough that a late drain-thread wake-up does not underrun and small enough
// that the added latency stays under the jitter buffer's own budget; on the
// capture side it is how far behind the reader may fall before the endpoint
// overwrites samples it has not collected yet. Both want the same number.
static const REFERENCE_TIME kBufferDurationHns = 1000000;

// Give up on a wedged device rather than blocking the drain thread forever. At
// one 20 ms buffer per call, two seconds without progress is not congestion.
static const DWORD kWriteTimeoutMs = 2000;
static const DWORD kWriteSleepMs = 5;

struct ts_wasapi {
    IAudioClient *client;
    IAudioRenderClient *render;
    UINT32 buffer_frames;
    UINT32 channels;
    /// Whether we own a CoUninitialize for this thread. False when the thread
    /// was already in an apartment we did not create.
    bool owns_com;
};

struct ts_wasapi_capture {
    IAudioClient *client;
    IAudioCaptureClient *capture;
    UINT32 channels;
    /// See ts_wasapi::owns_com.
    bool owns_com;
};

/// Is this the 32-bit float layout our samples are already in?
///
/// GetMixFormat returns WAVEFORMATEXTENSIBLE in practice, whose SubFormat GUID
/// encodes the old wFormatTag in Data1 — KSDATAFORMAT_SUBTYPE_IEEE_FLOAT is
/// {00000003-0000-0010-8000-00AA00389B71}, i.e. Data1 == WAVE_FORMAT_IEEE_FLOAT.
/// Comparing that field is the standard test and needs neither ksmedia.h nor a
/// GUID symbol to link against.
static bool ts_format_is_float32(const WAVEFORMATEX *wf) {
    if (wf->wBitsPerSample != 32) {
        return false;
    }
    if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        return true;
    }
    if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        wf->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        const WAVEFORMATEXTENSIBLE *ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(wf);
        return ext->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT;
    }
    return false;
}

/// Join this thread's COM apartment, reporting whether the balancing
/// `CoUninitialize` is ours to call.
///
/// S_FALSE means the thread was already initialised in the mode we asked for —
/// still ours to balance. RPC_E_CHANGED_MODE means someone put the thread in an
/// STA; the audio objects are usable either way, but the uninitialise is not
/// ours to call.
static HRESULT ts_com_enter(bool *owns_com) {
    *owns_com = false;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) {
        *owns_com = true;
        return S_OK;
    }
    return hr == RPC_E_CHANGED_MODE ? S_OK : hr;
}

/// Walk to the default endpoint for `flow`, activate its audio client, and hand
/// back the engine's mix format (the caller owns both and frees the format with
/// CoTaskMemFree).
///
/// Shared by both directions because both make the identical four-interface
/// climb — only the EDataFlow and the service asked of the client afterwards
/// differ. `eConsole` is the endpoint Windows itself would use, i.e. the one the
/// user's volume mixer and default-device UI control.
///
/// Not `eCommunications`, which Windows offers as a second default specifically
/// for calls. Two reasons: asking for it on capture while render already asks
/// for `eConsole` would let one machine record from a headset mic while playing
/// to desktop speakers, a split the user never configured; and moving BOTH onto
/// it is a behaviour change to a shipped playback path, which belongs in its own
/// commit rather than riding in on a capture feature.
static HRESULT ts_open_client(EDataFlow flow, IAudioClient **out_client, WAVEFORMATEX **out_mix) {
    // Everything the cleanup path touches is declared up front: a `goto` may
    // not cross an initialisation in C++.
    IMMDeviceEnumerator *enumerator = nullptr;
    IMMDevice *device = nullptr;
    IAudioClient *client = nullptr;
    WAVEFORMATEX *mix = nullptr;
    HRESULT hr = S_OK;

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator));
    if (FAILED(hr)) {
        goto done;
    }

    hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, &device);
    if (FAILED(hr)) {
        goto done;
    }

    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void **>(&client));
    if (FAILED(hr)) {
        goto done;
    }

    hr = client->GetMixFormat(&mix);
    if (FAILED(hr)) {
        goto done;
    }

    if (!ts_format_is_float32(mix)) {
        hr = static_cast<HRESULT>(TS_WASAPI_ERR_FORMAT);
        goto done;
    }

    *out_client = client;
    *out_mix = mix;
    client = nullptr;
    mix = nullptr;

done:
    if (mix != nullptr) {
        CoTaskMemFree(mix);
    }
    if (client != nullptr) {
        client->Release();
    }
    if (device != nullptr) {
        device->Release();
    }
    if (enumerator != nullptr) {
        enumerator->Release();
    }
    return hr;
}

extern "C" int32_t ts_wasapi_open(ts_wasapi **out, uint32_t *sample_rate, uint32_t *channels) {
    if (out == nullptr || sample_rate == nullptr || channels == nullptr) {
        return TS_WASAPI_ERR_ARGUMENT;
    }

    IAudioClient *client = nullptr;
    IAudioRenderClient *render = nullptr;
    WAVEFORMATEX *mix = nullptr;
    ts_wasapi *handle = nullptr;
    UINT32 buffer_frames = 0;
    bool owns_com = false;
    HRESULT hr = S_OK;

    hr = ts_com_enter(&owns_com);
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }

    hr = ts_open_client(eRender, &client, &mix);
    if (FAILED(hr)) {
        goto fail;
    }

    // Shared mode with the engine's own mix format is the one combination that
    // is always accepted without negotiation; the caller adapts its PCM to the
    // rate and channel count reported back.
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, kBufferDurationHns, 0, mix, nullptr);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = client->GetBufferSize(&buffer_frames);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = client->GetService(__uuidof(IAudioRenderClient), reinterpret_cast<void **>(&render));
    if (FAILED(hr)) {
        goto fail;
    }

    handle = static_cast<ts_wasapi *>(
        HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_wasapi)));
    if (handle == nullptr) {
        hr = E_OUTOFMEMORY;
        goto fail;
    }

    hr = client->Start();
    if (FAILED(hr)) {
        HeapFree(GetProcessHeap(), 0, handle);
        handle = nullptr;
        goto fail;
    }

    handle->client = client;
    handle->render = render;
    handle->buffer_frames = buffer_frames;
    handle->channels = mix->nChannels;
    handle->owns_com = owns_com;

    *sample_rate = mix->nSamplesPerSec;
    *channels = mix->nChannels;
    *out = handle;

    CoTaskMemFree(mix);
    return TS_WASAPI_OK;

fail:
    if (mix != nullptr) {
        CoTaskMemFree(mix);
    }
    if (render != nullptr) {
        render->Release();
    }
    if (client != nullptr) {
        client->Release();
    }
    if (owns_com) {
        CoUninitialize();
    }
    return static_cast<int32_t>(hr);
}

extern "C" int32_t ts_wasapi_write(ts_wasapi *handle, const float *interleaved, uint32_t frames) {
    if (handle == nullptr || interleaved == nullptr) {
        return TS_WASAPI_ERR_ARGUMENT;
    }
    if (frames == 0) {
        return TS_WASAPI_OK;
    }

    const UINT32 channels = handle->channels;
    const size_t frame_bytes = static_cast<size_t>(channels) * sizeof(float);
    uint32_t remaining = frames;
    const float *source = interleaved;
    DWORD waited_ms = 0;

    while (remaining > 0) {
        UINT32 padding = 0;
        HRESULT hr = handle->client->GetCurrentPadding(&padding);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }

        UINT32 available = handle->buffer_frames - padding;
        if (available == 0) {
            // The engine has not consumed anything yet. Sleeping a fraction of
            // the buffer keeps this from spinning while still waking well before
            // an underrun.
            if (waited_ms >= kWriteTimeoutMs) {
                return TS_WASAPI_ERR_TIMEOUT;
            }
            Sleep(kWriteSleepMs);
            waited_ms += kWriteSleepMs;
            continue;
        }
        waited_ms = 0;

        UINT32 chunk = available < remaining ? available : remaining;
        BYTE *destination = nullptr;
        hr = handle->render->GetBuffer(chunk, &destination);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }

        CopyMemory(destination, source, static_cast<size_t>(chunk) * frame_bytes);

        hr = handle->render->ReleaseBuffer(chunk, 0);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }

        source += static_cast<size_t>(chunk) * channels;
        remaining -= chunk;
    }

    return TS_WASAPI_OK;
}

extern "C" void ts_wasapi_close(ts_wasapi *handle) {
    if (handle == nullptr) {
        return;
    }
    if (handle->client != nullptr) {
        handle->client->Stop();
    }
    if (handle->render != nullptr) {
        handle->render->Release();
    }
    if (handle->client != nullptr) {
        handle->client->Release();
    }
    if (handle->owns_com) {
        CoUninitialize();
    }
    HeapFree(GetProcessHeap(), 0, handle);
}

extern "C" int32_t ts_wasapi_capture_open(ts_wasapi_capture **out, uint32_t *sample_rate,
                                          uint32_t *channels, uint32_t *buffer_frames) {
    if (out == nullptr || sample_rate == nullptr || channels == nullptr ||
        buffer_frames == nullptr) {
        return TS_WASAPI_ERR_ARGUMENT;
    }

    IAudioClient *client = nullptr;
    IAudioCaptureClient *capture = nullptr;
    WAVEFORMATEX *mix = nullptr;
    ts_wasapi_capture *handle = nullptr;
    UINT32 frames = 0;
    bool owns_com = false;
    HRESULT hr = S_OK;

    hr = ts_com_enter(&owns_com);
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }

    // E_ACCESSDENIED from here down is the microphone privacy setting, not a
    // fault: Windows 10+ refuses a capture client to an app the user has not
    // allowed. It travels back as its own HRESULT so the Swift layer can say so
    // rather than reporting a generic COM failure.
    hr = ts_open_client(eCapture, &client, &mix);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, kBufferDurationHns, 0, mix, nullptr);
    if (FAILED(hr)) {
        goto fail;
    }

    // The engine buffer bounds a single capture packet, so a reader whose
    // buffer holds this many frames can never be handed a packet it cannot
    // take. It is reported out for exactly that reason.
    hr = client->GetBufferSize(&frames);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void **>(&capture));
    if (FAILED(hr)) {
        goto fail;
    }

    handle = static_cast<ts_wasapi_capture *>(
        HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_wasapi_capture)));
    if (handle == nullptr) {
        hr = E_OUTOFMEMORY;
        goto fail;
    }

    hr = client->Start();
    if (FAILED(hr)) {
        HeapFree(GetProcessHeap(), 0, handle);
        handle = nullptr;
        goto fail;
    }

    handle->client = client;
    handle->capture = capture;
    handle->channels = mix->nChannels;
    handle->owns_com = owns_com;

    *sample_rate = mix->nSamplesPerSec;
    *channels = mix->nChannels;
    *buffer_frames = frames;
    *out = handle;

    CoTaskMemFree(mix);
    return TS_WASAPI_OK;

fail:
    if (mix != nullptr) {
        CoTaskMemFree(mix);
    }
    if (capture != nullptr) {
        capture->Release();
    }
    if (client != nullptr) {
        client->Release();
    }
    if (owns_com) {
        CoUninitialize();
    }
    return static_cast<int32_t>(hr);
}

extern "C" int32_t ts_wasapi_capture_read(ts_wasapi_capture *handle, float *interleaved,
                                          uint32_t capacity_frames, uint32_t *frames_read,
                                          int32_t *discontinuity) {
    if (handle == nullptr || interleaved == nullptr || frames_read == nullptr) {
        return TS_WASAPI_ERR_ARGUMENT;
    }
    *frames_read = 0;
    if (discontinuity != nullptr) {
        *discontinuity = 0;
    }
    if (capacity_frames == 0) {
        return TS_WASAPI_ERR_BUFFER_TOO_SMALL;
    }

    const UINT32 channels = handle->channels;
    const size_t frame_bytes = static_cast<size_t>(channels) * sizeof(float);
    uint32_t written = 0;

    // A failure part-way through discards whatever this call had already
    // collected — `*frames_read` stays 0. That is at most one engine buffer of
    // audio, lost at the moment the endpoint broke; the alternative is handing
    // back samples alongside an error, and a ReleaseBuffer that failed has left
    // its packet unacknowledged, so those same samples would arrive twice.
    for (;;) {
        UINT32 packet = 0;
        HRESULT hr = handle->capture->GetNextPacketSize(&packet);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }
        if (packet == 0) {
            // Nothing queued. The ordinary answer between device periods, not
            // an error: the caller polls again on its own clock.
            break;
        }
        if (packet > capacity_frames - written) {
            // Capture packets are all-or-nothing — ReleaseBuffer must
            // acknowledge the exact count GetBuffer reported — so a packet that
            // does not fit is left where it is for the next call. With nothing
            // read yet that would loop forever against a buffer that can never
            // take one, which is the caller's sizing bug and says so.
            if (written == 0) {
                return TS_WASAPI_ERR_BUFFER_TOO_SMALL;
            }
            break;
        }

        BYTE *data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = handle->capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }

        // GetBuffer can succeed with AUDCLNT_S_BUFFER_EMPTY — a SUCCESS code
        // meaning "nothing after all", so FAILED() does not catch it. Without
        // this break, a size query that keeps promising a packet the buffer
        // never delivers would spin this loop forever.
        if (frames == 0) {
            handle->capture->ReleaseBuffer(0);
            break;
        }

        // GetBuffer's own count wins over GetNextPacketSize's — believing the
        // earlier number would be a heap overwrite if they ever disagreed. A
        // packet that no longer fits is released unread (0 frames is the
        // documented "leave it queued" acknowledgement) rather than truncated.
        if (frames > capacity_frames - written) {
            handle->capture->ReleaseBuffer(0);
            if (written == 0) {
                return TS_WASAPI_ERR_BUFFER_TOO_SMALL;
            }
            break;
        }

        float *destination = interleaved + static_cast<size_t>(written) * channels;
        const size_t bytes = static_cast<size_t>(frames) * frame_bytes;
        if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
            // AUDCLNT_BUFFERFLAGS_SILENT does NOT mean the buffer holds zeros —
            // it means its contents are meaningless and the client must supply
            // the silence itself. Copying it instead is how a muted microphone
            // becomes full-scale noise on every viewer's speakers.
            ZeroMemory(destination, bytes);
        } else {
            CopyMemory(destination, data, bytes);
        }

        if (discontinuity != nullptr && (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0) {
            *discontinuity = 1;
        }

        hr = handle->capture->ReleaseBuffer(frames);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }

        written += frames;
        if (written == capacity_frames) {
            break;
        }
    }

    *frames_read = written;
    return TS_WASAPI_OK;
}

extern "C" void ts_wasapi_capture_close(ts_wasapi_capture *handle) {
    if (handle == nullptr) {
        return;
    }
    if (handle->client != nullptr) {
        handle->client->Stop();
    }
    if (handle->capture != nullptr) {
        handle->capture->Release();
    }
    if (handle->client != nullptr) {
        handle->client->Release();
    }
    if (handle->owns_com) {
        CoUninitialize();
    }
    HeapFree(GetProcessHeap(), 0, handle);
}

#endif  // _WIN32

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

// 100 ms of engine buffer, in 100-nanosecond units. Large enough that a late
// drain-thread wake-up does not underrun, small enough that the added latency
// stays under the jitter buffer's own budget.
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

extern "C" int32_t ts_wasapi_open(ts_wasapi **out, uint32_t *sample_rate, uint32_t *channels) {
    if (out == nullptr || sample_rate == nullptr || channels == nullptr) {
        return TS_WASAPI_ERR_ARGUMENT;
    }

    // Everything the cleanup path touches is declared up front: a `goto` may
    // not cross an initialisation in C++.
    IMMDeviceEnumerator *enumerator = nullptr;
    IMMDevice *device = nullptr;
    IAudioClient *client = nullptr;
    IAudioRenderClient *render = nullptr;
    WAVEFORMATEX *mix = nullptr;
    ts_wasapi *handle = nullptr;
    UINT32 buffer_frames = 0;
    bool owns_com = false;
    HRESULT hr = S_OK;

    // S_FALSE means this thread was already initialised in the mode we asked
    // for — still ours to balance. RPC_E_CHANGED_MODE means someone put the
    // thread in an STA; the objects below are usable either way, but the
    // uninitialise is not ours to call.
    hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) {
        owns_com = true;
    } else if (hr != RPC_E_CHANGED_MODE) {
        return static_cast<int32_t>(hr);
    }

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator));
    if (FAILED(hr)) {
        goto fail;
    }

    // eRender + eConsole: the endpoint Windows itself would use for playback,
    // which is what the user's volume mixer and default-device UI control.
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void **>(&client));
    if (FAILED(hr)) {
        goto fail;
    }

    hr = client->GetMixFormat(&mix);
    if (FAILED(hr)) {
        goto fail;
    }

    if (!ts_format_is_float32(mix)) {
        hr = static_cast<HRESULT>(TS_WASAPI_ERR_FORMAT);
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
    device->Release();
    enumerator->Release();
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
    if (device != nullptr) {
        device->Release();
    }
    if (enumerator != nullptr) {
        enumerator->Release();
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

#endif  // _WIN32

#include "include/ts_wasapi.h"

#ifdef _WIN32

// COBJMACROS turns each COM method into an `IAudioClient_Initialize(p, ...)`
// macro. Without it every call is `p->lpVtbl->Initialize(p, ...)`, which is the
// same thing with more places to write the wrong `p`.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <windows.h>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <stdlib.h>
#include <string.h>

// 100 ms of engine buffer, in 100-nanosecond units. Large enough that a late
// drain-thread wake-up does not underrun, small enough that the added latency
// stays under the jitter buffer's own budget.
#define TS_BUFFER_DURATION_HNS 1000000

// Give up on a wedged device rather than blocking the drain thread forever. At
// one 20 ms buffer per call, two seconds without progress is not congestion.
#define TS_WRITE_TIMEOUT_MS 2000

struct ts_wasapi {
    IAudioClient *client;
    IAudioRenderClient *render;
    UINT32 buffer_frames;
    UINT32 channels;
    /// Whether we own a CoUninitialize for this thread. False when the thread
    /// was already in an apartment we did not create.
    int owns_com;
};

/// Is this the 32-bit float layout our samples are already in?
///
/// GetMixFormat returns WAVEFORMATEXTENSIBLE in practice, whose SubFormat GUID
/// encodes the old wFormatTag in Data1 — KSDATAFORMAT_SUBTYPE_IEEE_FLOAT is
/// {00000003-0000-0010-8000-00AA00389B71}, i.e. Data1 == WAVE_FORMAT_IEEE_FLOAT.
/// Comparing that field is the standard test and avoids depending on ksmedia.h
/// defining the GUID symbol, which needs INITGUID and is easy to get subtly
/// wrong at link time.
static int ts_format_is_float32(const WAVEFORMATEX *wf) {
    if (wf->wBitsPerSample != 32) {
        return 0;
    }
    if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        return 1;
    }
    if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        wf->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        const WAVEFORMATEXTENSIBLE *ext = (const WAVEFORMATEXTENSIBLE *)wf;
        return ext->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT;
    }
    return 0;
}

int32_t ts_wasapi_open(ts_wasapi **out, uint32_t *sample_rate, uint32_t *channels) {
    if (out == NULL || sample_rate == NULL || channels == NULL) {
        return TS_WASAPI_ERR_ARGUMENT;
    }

    IMMDeviceEnumerator *enumerator = NULL;
    IMMDevice *device = NULL;
    IAudioClient *client = NULL;
    IAudioRenderClient *render = NULL;
    WAVEFORMATEX *mix = NULL;
    ts_wasapi *handle = NULL;
    int owns_com = 0;
    HRESULT hr;

    // S_FALSE means this thread was already initialised in the mode we asked
    // for — still ours to balance. RPC_E_CHANGED_MODE means someone put the
    // thread in an STA; the objects below are usable either way, but the
    // uninitialise is not ours to call.
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) {
        owns_com = 1;
    } else if (hr != RPC_E_CHANGED_MODE) {
        return (int32_t)hr;
    }

    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                          &IID_IMMDeviceEnumerator, (void **)&enumerator);
    if (FAILED(hr)) {
        goto fail;
    }

    // eRender + eConsole: the endpoint Windows itself would use for playback,
    // which is what the user's volume mixer and default-device UI control.
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = IMMDevice_Activate(device, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = IAudioClient_GetMixFormat(client, &mix);
    if (FAILED(hr)) {
        goto fail;
    }

    if (!ts_format_is_float32(mix)) {
        hr = (HRESULT)TS_WASAPI_ERR_FORMAT;
        goto fail;
    }

    // Shared mode with the engine's own mix format is the one combination that
    // is always accepted without negotiation; the caller adapts its PCM to the
    // rate and channel count reported back.
    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0,
                                 TS_BUFFER_DURATION_HNS, 0, mix, NULL);
    if (FAILED(hr)) {
        goto fail;
    }

    UINT32 buffer_frames = 0;
    hr = IAudioClient_GetBufferSize(client, &buffer_frames);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render);
    if (FAILED(hr)) {
        goto fail;
    }

    handle = (ts_wasapi *)calloc(1, sizeof(ts_wasapi));
    if (handle == NULL) {
        hr = E_OUTOFMEMORY;
        goto fail;
    }

    hr = IAudioClient_Start(client);
    if (FAILED(hr)) {
        free(handle);
        handle = NULL;
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
    IMMDevice_Release(device);
    IMMDeviceEnumerator_Release(enumerator);
    return TS_WASAPI_OK;

fail:
    if (mix != NULL) {
        CoTaskMemFree(mix);
    }
    if (render != NULL) {
        IAudioRenderClient_Release(render);
    }
    if (client != NULL) {
        IAudioClient_Release(client);
    }
    if (device != NULL) {
        IMMDevice_Release(device);
    }
    if (enumerator != NULL) {
        IMMDeviceEnumerator_Release(enumerator);
    }
    if (owns_com) {
        CoUninitialize();
    }
    return (int32_t)hr;
}

int32_t ts_wasapi_write(ts_wasapi *handle, const float *interleaved, uint32_t frames) {
    if (handle == NULL || interleaved == NULL) {
        return TS_WASAPI_ERR_ARGUMENT;
    }
    if (frames == 0) {
        return TS_WASAPI_OK;
    }

    const UINT32 channels = handle->channels;
    const size_t frame_bytes = (size_t)channels * sizeof(float);
    uint32_t remaining = frames;
    const float *source = interleaved;
    DWORD waited_ms = 0;

    while (remaining > 0) {
        UINT32 padding = 0;
        HRESULT hr = IAudioClient_GetCurrentPadding(handle->client, &padding);
        if (FAILED(hr)) {
            return (int32_t)hr;
        }

        UINT32 available = handle->buffer_frames - padding;
        if (available == 0) {
            // The engine has not consumed anything yet. Sleeping a fraction of
            // the buffer keeps this from spinning while still waking well before
            // an underrun.
            if (waited_ms >= TS_WRITE_TIMEOUT_MS) {
                return TS_WASAPI_ERR_TIMEOUT;
            }
            Sleep(5);
            waited_ms += 5;
            continue;
        }
        waited_ms = 0;

        UINT32 chunk = available < remaining ? available : remaining;
        BYTE *destination = NULL;
        hr = IAudioRenderClient_GetBuffer(handle->render, chunk, &destination);
        if (FAILED(hr)) {
            return (int32_t)hr;
        }

        memcpy(destination, source, (size_t)chunk * frame_bytes);

        hr = IAudioRenderClient_ReleaseBuffer(handle->render, chunk, 0);
        if (FAILED(hr)) {
            return (int32_t)hr;
        }

        source += (size_t)chunk * channels;
        remaining -= chunk;
    }

    return TS_WASAPI_OK;
}

void ts_wasapi_close(ts_wasapi *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->client != NULL) {
        IAudioClient_Stop(handle->client);
    }
    if (handle->render != NULL) {
        IAudioRenderClient_Release(handle->render);
    }
    if (handle->client != NULL) {
        IAudioClient_Release(handle->client);
    }
    if (handle->owns_com) {
        CoUninitialize();
    }
    free(handle);
}

#else

// Non-Windows: an empty translation unit. Keeping the package buildable
// everywhere means its manifest and Swift wrapper are checked by every job
// rather than only by the Windows one. ISO C forbids an empty translation
// unit, hence the declaration.
typedef int ts_wasapi_unused_translation_unit;

#endif  // _WIN32

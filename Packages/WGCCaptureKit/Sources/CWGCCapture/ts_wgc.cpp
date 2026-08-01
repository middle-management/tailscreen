#include "include/ts_wgc.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN

#include <windows.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <inspectable.h>
#include <roapi.h>
#include <shobjidl_core.h>
// timeBeginPeriod/timeEndPeriod. Not reachable through windows.h under
// WIN32_LEAN_AND_MEAN, and this is the modern header for them (mmsystem.h
// drags in the rest of the multimedia API for two functions).
#include <timeapi.h>
#include <windows.foundation.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winstring.h>

// No C++ standard library, for the reason in WASAPIKit's shim: MSVC's STL
// asserts a compiler version this toolchain's clang does not satisfy. Win32
// supplies allocation and copy.

namespace capture = ABI::Windows::Graphics::Capture;
namespace d3d11abi = ABI::Windows::Graphics::DirectX::Direct3D11;
namespace foundation = ABI::Windows::Foundation;

struct ts_wgc_item {
    capture::IGraphicsCaptureItem *item;
};

struct ts_wgc {
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    d3d11abi::IDirect3DDevice *rtDevice;
    capture::IDirect3D11CaptureFramePool *pool;
    capture::IGraphicsCaptureSession *session;
    capture::IGraphicsCaptureItem *item;
    ID3D11Texture2D *staging;
    UINT width;
    UINT height;
    bool mapped;
    bool raisedTimerResolution;
};

template <typename T>
static void ts_release(T **p) {
    if (p != nullptr && *p != nullptr) {
        (*p)->Release();
        *p = nullptr;
    }
}

/// WinRT needs an initialised apartment on the calling thread. S_FALSE means
/// already initialised the way we asked; RPC_E_CHANGED_MODE means someone else
/// chose, and the interfaces below work either way — so neither is fatal, and
/// neither is ours to undo.
static void ts_ensure_apartment(bool ui) {
    RoInitialize(ui ? RO_INIT_SINGLETHREADED : RO_INIT_MULTITHREADED);
}

/// Get an activation factory by runtime class name.
template <typename T>
static HRESULT ts_factory(const wchar_t *name, T **out) {
    HSTRING hs = nullptr;
    HRESULT hr = WindowsCreateString(name, static_cast<UINT32>(wcslen(name)), &hs);
    if (FAILED(hr)) {
        return hr;
    }
    hr = RoGetActivationFactory(hs, __uuidof(T), reinterpret_cast<void **>(out));
    WindowsDeleteString(hs);
    return hr;
}

int32_t ts_wgc_is_supported(void) {
    ts_ensure_apartment(false);
    capture::IGraphicsCaptureSessionStatics *statics = nullptr;
    HRESULT hr = ts_factory(
        L"Windows.Graphics.Capture.GraphicsCaptureSession", &statics);
    if (FAILED(hr) || statics == nullptr) {
        return 0;
    }
    boolean supported = false;
    hr = statics->IsSupported(&supported);
    ts_release(&statics);
    return (SUCCEEDED(hr) && supported) ? 1 : 0;
}

extern "C" int32_t ts_wgc_pick(void *owner_hwnd, ts_wgc_item **out) {
    if (out == nullptr) {
        return TS_WGC_ERR_ARGUMENT;
    }
    ts_ensure_apartment(true);

    capture::IGraphicsCapturePicker *picker = nullptr;
    IInitializeWithWindow *withWindow = nullptr;
    foundation::IAsyncOperation<capture::GraphicsCaptureItem *> *operation = nullptr;
    foundation::IAsyncInfo *info = nullptr;
    capture::IGraphicsCaptureItem *item = nullptr;
    ts_wgc_item *handle = nullptr;
    HRESULT hr = S_OK;

    {
        IInspectable *inspectable = nullptr;
        HSTRING hs = nullptr;
        const wchar_t *name = L"Windows.Graphics.Capture.GraphicsCapturePicker";
        hr = WindowsCreateString(name, static_cast<UINT32>(wcslen(name)), &hs);
        if (SUCCEEDED(hr)) {
            hr = RoActivateInstance(hs, &inspectable);
            WindowsDeleteString(hs);
        }
        if (FAILED(hr)) {
            return TS_WGC_ERR_UNAVAILABLE;
        }
        hr = inspectable->QueryInterface(
            __uuidof(capture::IGraphicsCapturePicker), reinterpret_cast<void **>(&picker));
        ts_release(&inspectable);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }
    }

    // The picker is modal system UI and parents itself to a window. Without
    // this it fails rather than picking a parent for us.
    //
    // A null owner is resolved rather than passed through. Callers that can
    // hand over their real HWND should, but a GUI toolkit does not always
    // surface one — swift-cross-ui does not — and `Initialize(nullptr)` is
    // rejected, which would make "the picker is unavailable in this app" the
    // reported cause of what is really a plumbing gap. The active window, then
    // the foreground window, are the same fallbacks a modal dialog would use.
    HWND owner = static_cast<HWND>(owner_hwnd);
    if (owner == nullptr) {
        owner = GetActiveWindow();
    }
    if (owner == nullptr) {
        owner = GetForegroundWindow();
    }
    hr = picker->QueryInterface(
        __uuidof(IInitializeWithWindow), reinterpret_cast<void **>(&withWindow));
    if (SUCCEEDED(hr)) {
        withWindow->Initialize(owner);
        ts_release(&withWindow);
    }

    hr = picker->PickSingleItemAsync(&operation);
    if (FAILED(hr) || operation == nullptr) {
        ts_release(&picker);
        return FAILED(hr) ? static_cast<int32_t>(hr) : TS_WGC_ERR_UNAVAILABLE;
    }

    hr = operation->QueryInterface(
        __uuidof(foundation::IAsyncInfo), reinterpret_cast<void **>(&info));
    if (FAILED(hr)) {
        ts_release(&operation);
        ts_release(&picker);
        return static_cast<int32_t>(hr);
    }

    // Poll the async status while pumping messages, rather than implementing an
    // IAsyncOperationCompletedHandler as a COM object. The picker needs a pump
    // regardless — it is a modal dialog — and a hand-written handler in raw ABI
    // fails by hanging silently, which is the worst failure mode available.
    foundation::AsyncStatus status = foundation::AsyncStatus::Started;
    for (;;) {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (FAILED(info->get_Status(&status)) || status != foundation::AsyncStatus::Started) {
            break;
        }
        // Wake on input or after 50 ms, so the loop is neither a spin nor a
        // source of lag in the picker's own UI.
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
    }

    if (status == foundation::AsyncStatus::Completed) {
        hr = operation->GetResults(&item);
    } else {
        hr = E_ABORT;
    }
    ts_release(&info);
    ts_release(&operation);
    ts_release(&picker);

    // A cancelled pick returns S_OK with a NULL item — the user closing the
    // picker is not an error, and reporting it as one would put an alert in
    // front of someone who just changed their mind.
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }
    if (item == nullptr) {
        return TS_WGC_ERR_CANCELLED;
    }

    handle = static_cast<ts_wgc_item *>(
        HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_wgc_item)));
    if (handle == nullptr) {
        ts_release(&item);
        return static_cast<int32_t>(E_OUTOFMEMORY);
    }
    handle->item = item;
    *out = handle;
    return TS_WGC_OK;
}

/// Shared tail of the two interop constructors.
static int32_t ts_wgc_wrap_item(capture::IGraphicsCaptureItem *item, ts_wgc_item **out) {
    ts_wgc_item *handle = static_cast<ts_wgc_item *>(
        HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_wgc_item)));
    if (handle == nullptr) {
        item->Release();
        return static_cast<int32_t>(E_OUTOFMEMORY);
    }
    handle->item = item;
    *out = handle;
    return TS_WGC_OK;
}

extern "C" int32_t ts_wgc_item_for_monitor(void *hmonitor, ts_wgc_item **out) {
    if (out == nullptr || hmonitor == nullptr) {
        return TS_WGC_ERR_ARGUMENT;
    }
    ts_ensure_apartment(false);
    IGraphicsCaptureItemInterop *interop = nullptr;
    HRESULT hr = ts_factory(L"Windows.Graphics.Capture.GraphicsCaptureItem", &interop);
    if (FAILED(hr)) {
        return TS_WGC_ERR_UNAVAILABLE;
    }
    capture::IGraphicsCaptureItem *item = nullptr;
    hr = interop->CreateForMonitor(
        static_cast<HMONITOR>(hmonitor), __uuidof(capture::IGraphicsCaptureItem),
        reinterpret_cast<void **>(&item));
    ts_release(&interop);
    if (FAILED(hr) || item == nullptr) {
        return static_cast<int32_t>(hr);
    }
    return ts_wgc_wrap_item(item, out);
}

extern "C" int32_t ts_wgc_item_for_window(void *hwnd, ts_wgc_item **out) {
    if (out == nullptr || hwnd == nullptr) {
        return TS_WGC_ERR_ARGUMENT;
    }
    ts_ensure_apartment(false);
    IGraphicsCaptureItemInterop *interop = nullptr;
    HRESULT hr = ts_factory(L"Windows.Graphics.Capture.GraphicsCaptureItem", &interop);
    if (FAILED(hr)) {
        return TS_WGC_ERR_UNAVAILABLE;
    }
    capture::IGraphicsCaptureItem *item = nullptr;
    hr = interop->CreateForWindow(
        static_cast<HWND>(hwnd), __uuidof(capture::IGraphicsCaptureItem),
        reinterpret_cast<void **>(&item));
    ts_release(&interop);
    if (FAILED(hr) || item == nullptr) {
        return static_cast<int32_t>(hr);
    }
    return ts_wgc_wrap_item(item, out);
}

extern "C" int32_t ts_wgc_item_name(ts_wgc_item *item, char *buffer, int32_t capacity) {
    if (item == nullptr || buffer == nullptr || capacity <= 0) {
        return TS_WGC_ERR_ARGUMENT;
    }
    HSTRING hs = nullptr;
    HRESULT hr = item->item->get_DisplayName(&hs);
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }
    UINT32 length = 0;
    const wchar_t *wide = WindowsGetStringRawBuffer(hs, &length);
    int written = WideCharToMultiByte(
        CP_UTF8, 0, wide, static_cast<int>(length), buffer, capacity - 1, nullptr, nullptr);
    WindowsDeleteString(hs);
    if (written < 0) {
        written = 0;
    }
    buffer[written] = '\0';
    return TS_WGC_OK;
}

extern "C" int32_t ts_wgc_item_size(ts_wgc_item *item, uint32_t *width, uint32_t *height) {
    if (item == nullptr) {
        return TS_WGC_ERR_ARGUMENT;
    }
    ABI::Windows::Graphics::SizeInt32 size = {};
    HRESULT hr = item->item->get_Size(&size);
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }
    if (width != nullptr) {
        *width = static_cast<uint32_t>(size.Width < 0 ? 0 : size.Width);
    }
    if (height != nullptr) {
        *height = static_cast<uint32_t>(size.Height < 0 ? 0 : size.Height);
    }
    return TS_WGC_OK;
}

extern "C" void ts_wgc_item_release(ts_wgc_item *item) {
    if (item == nullptr) {
        return;
    }
    ts_release(&item->item);
    HeapFree(GetProcessHeap(), 0, item);
}

extern "C" int32_t ts_wgc_open(
    ts_wgc_item *item, ts_wgc **out, uint32_t *width, uint32_t *height
) {
    if (item == nullptr || out == nullptr || width == nullptr || height == nullptr) {
        return TS_WGC_ERR_ARGUMENT;
    }
    ts_ensure_apartment(false);

    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    IDXGIDevice *dxgiDevice = nullptr;
    IInspectable *deviceInspectable = nullptr;
    d3d11abi::IDirect3DDevice *rtDevice = nullptr;
    capture::IDirect3D11CaptureFramePoolStatics2 *poolStatics = nullptr;
    capture::IDirect3D11CaptureFramePool *pool = nullptr;
    capture::IGraphicsCaptureSession *session = nullptr;
    ID3D11Texture2D *staging = nullptr;
    ts_wgc *handle = nullptr;
    bool raisedTimerResolution = false;
    ABI::Windows::Graphics::SizeInt32 size = {};
    D3D11_TEXTURE2D_DESC stagingDesc = {};
    HRESULT hr = S_OK;

    hr = item->item->get_Size(&size);
    if (FAILED(hr) || size.Width <= 0 || size.Height <= 0) {
        return FAILED(hr) ? static_cast<int32_t>(hr) : TS_WGC_ERR_CLOSED;
    }

    hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(&dxgiDevice));
    if (FAILED(hr)) {
        goto fail;
    }
    // WGC takes a WinRT device, not a D3D11 one; this is the documented bridge.
    hr = CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, &deviceInspectable);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = deviceInspectable->QueryInterface(
        __uuidof(d3d11abi::IDirect3DDevice), reinterpret_cast<void **>(&rtDevice));
    if (FAILED(hr)) {
        goto fail;
    }

    hr = ts_factory(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool", &poolStatics);
    if (FAILED(hr)) {
        hr = static_cast<HRESULT>(TS_WGC_ERR_UNAVAILABLE);
        goto fail;
    }
    // CreateFreeThreaded, not Create: the latter delivers frames on the
    // creating thread's dispatcher, which would put every frame on the UI
    // thread. Free-threaded lets the capture thread pull them.
    //
    // Two buffers. WGC's own samples use two; more only adds latency, since a
    // frame we have not pulled yet is a frame the viewer is not seeing.
    hr = poolStatics->CreateFreeThreaded(
        rtDevice, ABI::Windows::Graphics::DirectX::DirectXPixelFormat_B8G8R8A8UIntNormalized,
        2, size, &pool);
    if (FAILED(hr)) {
        goto fail;
    }

    hr = pool->CreateCaptureSession(item->item, &session);
    if (FAILED(hr)) {
        goto fail;
    }
    // Ask for a 1 ms system timer while capturing.
    //
    // Windows' default is 15.6 ms, which is longer than a frame at any rate
    // worth sharing — so every `Sleep` in the acquire loop below overshoots
    // its deadline and the loop misses frames it was awake for. This is the
    // same request media players and capture software make, and it is scoped:
    // ts_wgc_close gives it back, so an idle Tailscreen does not hold the
    // whole machine at a high timer rate.
    timeBeginPeriod(1);
    raisedTimerResolution = true;

    hr = session->StartCapture();
    if (FAILED(hr)) {
        goto fail;
    }

    stagingDesc.Width = static_cast<UINT>(size.Width);
    stagingDesc.Height = static_cast<UINT>(size.Height);
    stagingDesc.MipLevels = 1;
    stagingDesc.ArraySize = 1;
    stagingDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    stagingDesc.SampleDesc.Count = 1;
    stagingDesc.Usage = D3D11_USAGE_STAGING;
    stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = device->CreateTexture2D(&stagingDesc, nullptr, &staging);
    if (FAILED(hr)) {
        goto fail;
    }

    handle = static_cast<ts_wgc *>(HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_wgc)));
    if (handle == nullptr) {
        hr = E_OUTOFMEMORY;
        goto fail;
    }

    item->item->AddRef();
    handle->device = device;
    handle->context = context;
    handle->rtDevice = rtDevice;
    handle->pool = pool;
    handle->session = session;
    handle->item = item->item;
    handle->staging = staging;
    handle->width = static_cast<UINT>(size.Width);
    handle->height = static_cast<UINT>(size.Height);
    // Ownership of the timer request moves to the handle here, so ts_wgc_close
    // gives it back. Tracked in a LOCAL until this point because `handle` does
    // not exist yet when the request is made — writing the flag through it
    // earlier dereferenced null.
    handle->raisedTimerResolution = raisedTimerResolution;
    raisedTimerResolution = false;

    *width = handle->width;
    *height = handle->height;
    *out = handle;

    ts_release(&deviceInspectable);
    ts_release(&dxgiDevice);
    ts_release(&poolStatics);
    return TS_WGC_OK;

fail:
    // Still ours if the handle was never built — otherwise the request leaks
    // and the machine stays at a 1 ms timer for the life of the process.
    if (raisedTimerResolution) {
        timeEndPeriod(1);
    }
    ts_release(&staging);
    ts_release(&session);
    ts_release(&pool);
    ts_release(&poolStatics);
    ts_release(&rtDevice);
    ts_release(&deviceInspectable);
    ts_release(&dxgiDevice);
    ts_release(&context);
    ts_release(&device);
    return static_cast<int32_t>(hr);
}

extern "C" int32_t ts_wgc_acquire(
    ts_wgc *handle, uint32_t timeout_ms, const uint8_t **bgra, int32_t *stride
) {
    if (handle == nullptr || bgra == nullptr || stride == nullptr) {
        return TS_WGC_ERR_ARGUMENT;
    }
    if (handle->mapped) {
        return TS_WGC_ERR_BUSY;
    }

    // TryGetNextFrame is non-blocking and returns NULL when nothing is ready,
    // so the timeout is ours to implement. Polling rather than subscribing to
    // FrameArrived for the same reason the picker polls: an event handler here
    // is a COM object in raw ABI, and the caller wants a pull API anyway.
    capture::IDirect3D11CaptureFrame *frame = nullptr;
    const DWORD deadline = GetTickCount() + timeout_ms;
    for (;;) {
        HRESULT hr = handle->pool->TryGetNextFrame(&frame);
        if (FAILED(hr)) {
            return static_cast<int32_t>(hr);
        }
        if (frame != nullptr) {
            break;
        }
        // Signed comparison so the 49-day GetTickCount wrap does not turn into
        // a ~forever wait.
        if (static_cast<LONG>(GetTickCount() - deadline) >= 0) {
            return TS_WGC_TIMEOUT;
        }
        // Sleep(1), and only meaningful because ts_wgc_open raised the
        // system timer resolution. At Windows' DEFAULT 15.6 ms granularity a
        // `Sleep(2)` here really slept ~15.6 ms, so a poll loop budgeted 16 ms
        // overshot on its FIRST wait — which is why measured capture time came
        // back as 24 ms against a 16 ms deadline, and why frames arriving
        // during that overshoot were missed rather than picked up.
        Sleep(1);
    }

    d3d11abi::IDirect3DSurface *surface = nullptr;
    Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess *access = nullptr;
    ID3D11Texture2D *texture = nullptr;
    HRESULT hr = frame->get_Surface(&surface);
    if (SUCCEEDED(hr)) {
        hr = surface->QueryInterface(
            __uuidof(Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess),
            reinterpret_cast<void **>(&access));
    }
    if (SUCCEEDED(hr)) {
        hr = access->GetInterface(
            __uuidof(ID3D11Texture2D), reinterpret_cast<void **>(&texture));
    }
    if (SUCCEEDED(hr)) {
        handle->context->CopyResource(handle->staging, texture);
    }
    ts_release(&texture);
    ts_release(&access);
    ts_release(&surface);
    // Release the frame back to the pool before mapping: holding it starves the
    // pool's two buffers while the CPU converts.
    ts_release(&frame);
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }

    D3D11_MAPPED_SUBRESOURCE mapped = {};
    hr = handle->context->Map(handle->staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }
    handle->mapped = true;
    *bgra = static_cast<const uint8_t *>(mapped.pData);
    *stride = static_cast<int32_t>(mapped.RowPitch);
    return TS_WGC_OK;
}

extern "C" void ts_wgc_release(ts_wgc *handle) {
    if (handle == nullptr || !handle->mapped) {
        return;
    }
    handle->context->Unmap(handle->staging, 0);
    handle->mapped = false;
}

extern "C" void ts_wgc_close(ts_wgc *handle) {
    if (handle == nullptr) {
        return;
    }
    // Give the system timer resolution back. Every timeBeginPeriod needs its
    // matching timeEndPeriod — the request is reference-counted process-wide,
    // and leaking one holds the whole machine at 1 ms for as long as
    // Tailscreen is running, share or no share.
    if (handle->raisedTimerResolution) {
        timeEndPeriod(1);
        handle->raisedTimerResolution = false;
    }
    ts_wgc_release(handle);
    ts_release(&handle->staging);
    ts_release(&handle->session);
    ts_release(&handle->pool);
    ts_release(&handle->item);
    ts_release(&handle->rtDevice);
    ts_release(&handle->context);
    ts_release(&handle->device);
    HeapFree(GetProcessHeap(), 0, handle);
}

#endif  // _WIN32

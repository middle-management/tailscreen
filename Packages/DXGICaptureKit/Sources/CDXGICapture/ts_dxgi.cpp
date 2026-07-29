#include "include/ts_dxgi.h"

#ifdef _WIN32

// C++ for `__uuidof`, and NO C++ standard library — both for the reasons
// spelled out at the top of WASAPIKit's ts_wasapi.cpp. In short: the GUIDs come
// from the SDK headers' own DECLSPEC_UUID annotations rather than being typed
// out (a hand-copied GUID fails at run time with E_NOINTERFACE, which no CI job
// can catch), and MSVC's STL hard-asserts a compiler version the Swift
// toolchain's clang does not satisfy. Win32 supplies the allocation and copy
// this file needs.

#define WIN32_LEAN_AND_MEAN

#include <windows.h>

#include <d3d11.h>
#include <dxgi1_2.h>

struct ts_dxgi {
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGIOutputDuplication *duplication;
    /// CPU-readable copy target. Duplication hands back a GPU texture that
    /// cannot be mapped directly, so every frame is copied here first.
    ID3D11Texture2D *staging;
    UINT width;
    UINT height;
    bool mapped;
};

/// Release a COM pointer and null it, so the cleanup path is idempotent and a
/// double-close cannot double-release.
template <typename T>
static void ts_release(T **p) {
    if (p != nullptr && *p != nullptr) {
        (*p)->Release();
        *p = nullptr;
    }
}

extern "C" int32_t ts_dxgi_open(
    ts_dxgi **out, uint32_t output_index, uint32_t *width, uint32_t *height
) {
    if (out == nullptr || width == nullptr || height == nullptr) {
        return TS_DXGI_ERR_ARGUMENT;
    }

    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    IDXGIDevice *dxgiDevice = nullptr;
    IDXGIAdapter *adapter = nullptr;
    IDXGIOutput *output = nullptr;
    IDXGIOutput1 *output1 = nullptr;
    IDXGIOutputDuplication *duplication = nullptr;
    ID3D11Texture2D *staging = nullptr;
    ts_dxgi *handle = nullptr;
    DXGI_OUTPUT_DESC outputDesc = {};
    D3D11_TEXTURE2D_DESC stagingDesc = {};
    UINT w = 0;
    UINT h = 0;
    HRESULT hr = S_OK;

    // BGRA support is required because the duplication surface is
    // B8G8R8A8_UNORM and the staging copy must match it. No debug layer: it is
    // absent on machines without the SDK's developer components, and asking for
    // it there fails device creation outright.
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

    hr = dxgiDevice->GetParent(__uuidof(IDXGIAdapter), reinterpret_cast<void **>(&adapter));
    if (FAILED(hr)) {
        goto fail;
    }

    hr = adapter->EnumOutputs(output_index, &output);
    if (hr == DXGI_ERROR_NOT_FOUND) {
        hr = static_cast<HRESULT>(TS_DXGI_ERR_NO_OUTPUT);
        goto fail;
    }
    if (FAILED(hr)) {
        goto fail;
    }

    hr = output->GetDesc(&outputDesc);
    if (FAILED(hr)) {
        goto fail;
    }
    // DesktopCoordinates is a virtual-desktop rect, so the width is a
    // difference and not an absolute — a secondary monitor left of the primary
    // has negative coordinates.
    w = static_cast<UINT>(outputDesc.DesktopCoordinates.right - outputDesc.DesktopCoordinates.left);
    h = static_cast<UINT>(outputDesc.DesktopCoordinates.bottom - outputDesc.DesktopCoordinates.top);
    if (w == 0 || h == 0) {
        hr = static_cast<HRESULT>(TS_DXGI_ERR_NO_OUTPUT);
        goto fail;
    }

    hr = output->QueryInterface(__uuidof(IDXGIOutput1), reinterpret_cast<void **>(&output1));
    if (FAILED(hr)) {
        goto fail;
    }

    hr = output1->DuplicateOutput(device, &duplication);
    if (FAILED(hr)) {
        goto fail;
    }

    stagingDesc.Width = w;
    stagingDesc.Height = h;
    stagingDesc.MipLevels = 1;
    stagingDesc.ArraySize = 1;
    stagingDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    stagingDesc.SampleDesc.Count = 1;
    stagingDesc.Usage = D3D11_USAGE_STAGING;
    stagingDesc.BindFlags = 0;
    stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    stagingDesc.MiscFlags = 0;
    hr = device->CreateTexture2D(&stagingDesc, nullptr, &staging);
    if (FAILED(hr)) {
        goto fail;
    }

    handle = static_cast<ts_dxgi *>(
        HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_dxgi)));
    if (handle == nullptr) {
        hr = E_OUTOFMEMORY;
        goto fail;
    }

    handle->device = device;
    handle->context = context;
    handle->duplication = duplication;
    handle->staging = staging;
    handle->width = w;
    handle->height = h;
    handle->mapped = false;

    *width = w;
    *height = h;
    *out = handle;

    // The intermediates are ours to drop; the four kept alive are in `handle`.
    ts_release(&output1);
    ts_release(&output);
    ts_release(&adapter);
    ts_release(&dxgiDevice);
    return TS_DXGI_OK;

fail:
    ts_release(&staging);
    ts_release(&duplication);
    ts_release(&output1);
    ts_release(&output);
    ts_release(&adapter);
    ts_release(&dxgiDevice);
    ts_release(&context);
    ts_release(&device);
    return static_cast<int32_t>(hr);
}

extern "C" int32_t ts_dxgi_acquire(
    ts_dxgi *handle, uint32_t timeout_ms, const uint8_t **bgra, int32_t *stride
) {
    if (handle == nullptr || bgra == nullptr || stride == nullptr) {
        return TS_DXGI_ERR_ARGUMENT;
    }
    if (handle->mapped) {
        return TS_DXGI_ERR_BUSY;
    }

    DXGI_OUTDUPL_FRAME_INFO info = {};
    IDXGIResource *resource = nullptr;
    HRESULT hr = handle->duplication->AcquireNextFrame(timeout_ms, &info, &resource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        return TS_DXGI_TIMEOUT;
    }
    if (hr == DXGI_ERROR_ACCESS_LOST) {
        return TS_DXGI_ERR_LOST;
    }
    if (FAILED(hr)) {
        return static_cast<int32_t>(hr);
    }

    ID3D11Texture2D *frame = nullptr;
    hr = resource->QueryInterface(__uuidof(ID3D11Texture2D), reinterpret_cast<void **>(&frame));
    if (SUCCEEDED(hr)) {
        handle->context->CopyResource(handle->staging, frame);
        ts_release(&frame);
    }
    ts_release(&resource);

    // Release the FRAME as soon as it is copied, before mapping. Duplication
    // allows one outstanding frame, and holding it across the map would stall
    // the desktop compositor for as long as the caller takes to convert.
    handle->duplication->ReleaseFrame();

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
    return TS_DXGI_OK;
}

extern "C" void ts_dxgi_release(ts_dxgi *handle) {
    if (handle == nullptr || !handle->mapped) {
        return;
    }
    handle->context->Unmap(handle->staging, 0);
    handle->mapped = false;
}

extern "C" void ts_dxgi_close(ts_dxgi *handle) {
    if (handle == nullptr) {
        return;
    }
    ts_dxgi_release(handle);
    ts_release(&handle->staging);
    ts_release(&handle->duplication);
    ts_release(&handle->context);
    ts_release(&handle->device);
    HeapFree(GetProcessHeap(), 0, handle);
}

#endif  // _WIN32

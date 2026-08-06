// D3D11 YUV->RGB for the Windows viewer. See include/cwinvideo.h for what this
// deliberately does not do (no letterbox, no zoom — XAML already does both on
// the GPU).
//
// C++ rather than C because D3D11 is COM: from C every call is an explicit
// vtable dereference, which buys nothing here and hides the one thing worth
// reading, the draw path. The interface stays `extern "C"` so Swift imports it
// as a plain C module, exactly as `CGtkVideo` is imported on Linux.

#include "include/cwinvideo.h"

// Compiled to nothing off Windows. The `linux-app` job typechecks the Windows
// app on Linux (that is where the WinUI sources get their only per-PR check), so
// a target that unconditionally includes <d3d11.h> fails a leg that has no
// business building D3D at all. Same shape as WinNotifyKit's shim, for the same
// reason.
#if defined(_WIN32)

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

// ISurfaceImageSourceNative, declared here rather than included.
//
// The interface lives in `microsoft.ui.xaml.media.dxinterop.h`, which the
// swift-winui dependency vendors at Sources/CWinAppSDK/nuget/include/ — but that
// directory is not any target's public headers path and CWinAppSDK is not an
// exported product, so there is no supported way to include it from here. The
// first attempt did and CI answered "'microsoft.ui.xaml.media.dxinterop.h' file
// not found".
//
// So the three methods we call are declared directly. The IID and the vtable
// order are copied from that vendored header, NOT guessed: WinUI 3's
// Microsoft.UI.Xaml interface has a different IID from the UWP
// Windows.UI.Xaml one of the same name, and a wrong GUID here would fail at
// QueryInterface — at runtime, in a viewer, with nothing at compile time to
// catch it.
struct __declspec(uuid("e4cecd6c-f14b-4f46-83c3-8bbda27c6504"))
    ISurfaceImageSourceNative : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE SetDevice(IDXGIDevice *device) = 0;
    virtual HRESULT STDMETHODCALLTYPE BeginDraw(RECT updateRect,
                                               IDXGISurface **surface,
                                               POINT *offset) = 0;
    virtual HRESULT STDMETHODCALLTYPE EndDraw(void) = 0;
};

namespace {

// One BT.709 limited-range conversion, and the overlay composite in the same
// pass. Compiled at runtime with D3DCompile rather than precompiled: the app
// already ships d3dcompiler_47.dll with the self-contained runtime, and a
// shader blob checked into the repo is a binary nobody can review.
//
// The vertex stage generates a fullscreen triangle from SV_VertexID, so there
// is no vertex buffer, no input layout, and nothing to keep in sync with a
// struct. The surface IS the video's resolution, so texture coordinates are the
// identity — every letterbox/aspect question belongs to the element, not here.
const char *kShaderSource = R"HLSL(
Texture2D<float> texY : register(t0);
Texture2D<float> texU : register(t1);
Texture2D<float> texV : register(t2);
Texture2D<float4> texOverlay : register(t3);
SamplerState samp : register(s0);

cbuffer Params : register(b0) {
    float hasOverlay;
    float3 pad;
};

struct VSOut {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

VSOut vs_main(uint vid : SV_VertexID) {
    // Two triangles' worth of a fullscreen quad from four vertices, drawn as a
    // strip: (0,0) (1,0) (0,1) (1,1) in UV, mapped to NDC.
    float2 uv = float2((vid == 1 || vid == 3) ? 1.0 : 0.0,
                       (vid == 2 || vid == 3) ? 1.0 : 0.0);
    VSOut o;
    o.uv = uv;
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return o;
}

float4 ps_main(VSOut i) : SV_TARGET {
    // Limited range: Y is 16..235, chroma 16..240 about 128. Same constants as
    // the GL shader and as I420Converter — if these three ever disagree the
    // WARP self-test against ColorBars is what says so.
    float y = (texY.Sample(samp, i.uv) * 255.0 - 16.0) / 219.0;
    float u = (texU.Sample(samp, i.uv) * 255.0 - 128.0) / 224.0;
    float v = (texV.Sample(samp, i.uv) * 255.0 - 128.0) / 224.0;

    float3 rgb;
    rgb.r = y + 1.5748 * v;
    rgb.g = y - 0.1873 * u - 0.4681 * v;
    rgb.b = y + 1.8556 * u;
    rgb = saturate(rgb);

    if (hasOverlay > 0.5) {
        // PREMULTIPLIED source, so `o.rgb` is already scaled by `o.a` — the
        // rasterizer premultiplies because UpdateLayeredWindow requires it.
        // Multiplying by alpha again here would darken every antialiased stroke
        // edge toward black and make a half-transparent stroke a quarter as
        // bright as it should be.
        float4 o = texOverlay.Sample(samp, i.uv);
        rgb = rgb * (1.0 - o.a) + o.rgb;
    }
    // Opaque: the source is created opaque, and a stray alpha here shows up as
    // the desktop bleeding through the video.
    return float4(rgb, 1.0);
}
)HLSL";

template <class T> void release(T *&p) {
    if (p) {
        p->Release();
        p = nullptr;
    }
}

struct State {
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    ID3D11VertexShader *vs = nullptr;
    ID3D11PixelShader *ps = nullptr;
    ID3D11SamplerState *sampler = nullptr;
    ID3D11Buffer *params = nullptr;
    ID3D11BlendState *blend = nullptr;

    // Plane textures, reallocated only on a resolution change.
    ID3D11Texture2D *texY = nullptr;
    ID3D11Texture2D *texU = nullptr;
    ID3D11Texture2D *texV = nullptr;
    ID3D11Texture2D *texOverlay = nullptr;
    ID3D11ShaderResourceView *srvY = nullptr;
    ID3D11ShaderResourceView *srvU = nullptr;
    ID3D11ShaderResourceView *srvV = nullptr;
    ID3D11ShaderResourceView *srvOverlay = nullptr;
    int texWidth = 0;
    int texHeight = 0;

    ISurfaceImageSourceNative *source = nullptr;
    int sourceWidth = 0;
    int sourceHeight = 0;

    bool deviceLost = false;
};

State g;

void logOnce(const char *what, HRESULT hr) {
    // Deliberately not rate-limited per message: each of these is a one-shot
    // setup failure, and a viewer that silently falls back to the CPU path with
    // no line in the log is the failure mode this whole diagnostics arc was
    // about.
    fprintf(stderr, "[winvideo] %s failed: 0x%08lX\n", what, (unsigned long)hr);
    fflush(stderr);
}

// Dynamic, CPU-written, one byte per texel. R8_UNORM rather than a single NV12
// texture: the decoder hands us three tightly-packed planes and this keeps the
// upload a straight row copy per plane with no interleave step.
bool makePlaneTexture(int w, int h, ID3D11Texture2D **tex,
                      ID3D11ShaderResourceView **srv, DXGI_FORMAT fmt) {
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = (UINT)w;
    d.Height = (UINT)h;
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = fmt;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DYNAMIC;
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    d.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    HRESULT hr = g.device->CreateTexture2D(&d, nullptr, tex);
    if (FAILED(hr)) {
        logOnce("CreateTexture2D", hr);
        return false;
    }
    hr = g.device->CreateShaderResourceView(*tex, nullptr, srv);
    if (FAILED(hr)) {
        logOnce("CreateShaderResourceView", hr);
        return false;
    }
    return true;
}

void releaseTextures() {
    release(g.srvY);
    release(g.srvU);
    release(g.srvV);
    release(g.srvOverlay);
    release(g.texY);
    release(g.texU);
    release(g.texV);
    release(g.texOverlay);
    g.texWidth = 0;
    g.texHeight = 0;
}

bool ensureTextures(int w, int h) {
    if (g.texWidth == w && g.texHeight == h && g.texY) return true;
    releaseTextures();
    const int cw = (w + 1) / 2;
    const int ch = (h + 1) / 2;
    if (!makePlaneTexture(w, h, &g.texY, &g.srvY, DXGI_FORMAT_R8_UNORM)) return false;
    if (!makePlaneTexture(cw, ch, &g.texU, &g.srvU, DXGI_FORMAT_R8_UNORM)) return false;
    if (!makePlaneTexture(cw, ch, &g.texV, &g.srvV, DXGI_FORMAT_R8_UNORM)) return false;
    // B8G8R8A8, not R8G8B8A8: the overlay arrives from the portable
    // `AnnotationRasterizer`, which writes b,g,r,a in that byte order because
    // that is what `UpdateLayeredWindow` composites directly. Declaring the
    // texture RGBA would sample byte 0 as `.r` and swap red with blue in every
    // stroke — a wrong picture, not a build error, which is exactly the kind of
    // mistake the WARP self-test exists to catch.
    if (!makePlaneTexture(w, h, &g.texOverlay, &g.srvOverlay,
                          DXGI_FORMAT_B8G8R8A8_UNORM))
        return false;
    g.texWidth = w;
    g.texHeight = h;
    return true;
}

// Row-by-row because the mapped RowPitch is the driver's, not ours: the plane is
// tightly packed at `srcStride` and almost never matches.
bool uploadPlane(ID3D11Texture2D *tex, const uint8_t *src, int srcStride, int w,
                 int h, int bytesPerTexel) {
    D3D11_MAPPED_SUBRESOURCE m = {};
    HRESULT hr = g.context->Map(tex, 0, D3D11_MAP_WRITE_DISCARD, 0, &m);
    if (FAILED(hr)) {
        if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
            g.deviceLost = true;
        }
        logOnce("Map(plane)", hr);
        return false;
    }
    const int rowBytes = w * bytesPerTexel;
    uint8_t *dst = (uint8_t *)m.pData;
    for (int row = 0; row < h; ++row) {
        memcpy(dst + (size_t)row * m.RowPitch, src + (size_t)row * srcStride,
               (size_t)rowBytes);
    }
    g.context->Unmap(tex, 0);
    return true;
}

void setParams(bool hasOverlay) {
    float v[4] = {hasOverlay ? 1.0f : 0.0f, 0, 0, 0};
    D3D11_MAPPED_SUBRESOURCE m = {};
    if (SUCCEEDED(g.context->Map(g.params, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
        memcpy(m.pData, v, sizeof(v));
        g.context->Unmap(g.params, 0);
    }
}

// Shared by draw and clear: BeginDraw hands back a surface out of an ATLAS, so
// the offset it reports is not decoration — drawing at 0,0 lands on someone
// else's pixels.
bool beginTarget(ID3D11RenderTargetView **rtv, POINT *offset, RECT *rect) {
    if (!g.source) return false;
    *rect = {0, 0, (LONG)g.sourceWidth, (LONG)g.sourceHeight};
    IDXGISurface *surface = nullptr;
    HRESULT hr = g.source->BeginDraw(*rect, &surface, offset);
    if (FAILED(hr)) {
        if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
            g.deviceLost = true;
        }
        logOnce("BeginDraw", hr);
        return false;
    }
    ID3D11Texture2D *tex = nullptr;
    hr = surface->QueryInterface(__uuidof(ID3D11Texture2D), (void **)&tex);
    surface->Release();
    if (FAILED(hr)) {
        logOnce("QueryInterface(ID3D11Texture2D)", hr);
        g.source->EndDraw();
        return false;
    }
    hr = g.device->CreateRenderTargetView(tex, nullptr, rtv);
    tex->Release();
    if (FAILED(hr)) {
        logOnce("CreateRenderTargetView", hr);
        g.source->EndDraw();
        return false;
    }
    return true;
}

}  // namespace

extern "C" {

int32_t winvideo_init(void) {
    if (g.device) return 1;
    g.deviceLost = false;

    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    const D3D_DRIVER_TYPE types[] = {D3D_DRIVER_TYPE_HARDWARE,
                                     D3D_DRIVER_TYPE_WARP};
    HRESULT hr = E_FAIL;
    for (D3D_DRIVER_TYPE type : types) {
        hr = D3D11CreateDevice(nullptr, type, nullptr, flags, nullptr, 0,
                               D3D11_SDK_VERSION, &g.device, nullptr,
                               &g.context);
        if (SUCCEEDED(hr)) break;
    }
    if (FAILED(hr)) {
        logOnce("D3D11CreateDevice", hr);
        return 0;
    }

    ID3DBlob *vsBlob = nullptr, *psBlob = nullptr, *err = nullptr;
    hr = D3DCompile(kShaderSource, strlen(kShaderSource), "cwinvideo", nullptr,
                    nullptr, "vs_main", "vs_4_0", 0, 0, &vsBlob, &err);
    if (FAILED(hr)) {
        if (err) {
            fprintf(stderr, "[winvideo] vs compile: %.*s\n",
                    (int)err->GetBufferSize(), (const char *)err->GetBufferPointer());
            err->Release();
        }
        winvideo_reset();
        return 0;
    }
    hr = D3DCompile(kShaderSource, strlen(kShaderSource), "cwinvideo", nullptr,
                    nullptr, "ps_main", "ps_4_0", 0, 0, &psBlob, &err);
    if (FAILED(hr)) {
        if (err) {
            fprintf(stderr, "[winvideo] ps compile: %.*s\n",
                    (int)err->GetBufferSize(), (const char *)err->GetBufferPointer());
            err->Release();
        }
        release(vsBlob);
        winvideo_reset();
        return 0;
    }
    hr = g.device->CreateVertexShader(vsBlob->GetBufferPointer(),
                                      vsBlob->GetBufferSize(), nullptr, &g.vs);
    if (SUCCEEDED(hr)) {
        hr = g.device->CreatePixelShader(psBlob->GetBufferPointer(),
                                         psBlob->GetBufferSize(), nullptr, &g.ps);
    }
    release(vsBlob);
    release(psBlob);
    if (FAILED(hr)) {
        logOnce("Create*Shader", hr);
        winvideo_reset();
        return 0;
    }

    D3D11_SAMPLER_DESC sd = {};
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    hr = g.device->CreateSamplerState(&sd, &g.sampler);
    if (FAILED(hr)) {
        logOnce("CreateSamplerState", hr);
        winvideo_reset();
        return 0;
    }

    D3D11_BUFFER_DESC bd = {};
    bd.ByteWidth = 16;  // one float4, the constant-buffer minimum
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = g.device->CreateBuffer(&bd, nullptr, &g.params);
    if (FAILED(hr)) {
        logOnce("CreateBuffer(params)", hr);
        winvideo_reset();
        return 0;
    }
    return 1;
}

int32_t winvideo_bind_source(void *surface_image_source_unknown, int32_t width,
                             int32_t height) {
    if (!g.device || !surface_image_source_unknown) return 0;
    release(g.source);
    IUnknown *unk = (IUnknown *)surface_image_source_unknown;
    HRESULT hr = unk->QueryInterface(__uuidof(ISurfaceImageSourceNative),
                                     (void **)&g.source);
    if (FAILED(hr)) {
        logOnce("QueryInterface(ISurfaceImageSourceNative)", hr);
        return 0;
    }
    IDXGIDevice *dxgi = nullptr;
    hr = g.device->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgi);
    if (FAILED(hr)) {
        logOnce("QueryInterface(IDXGIDevice)", hr);
        release(g.source);
        return 0;
    }
    hr = g.source->SetDevice(dxgi);
    dxgi->Release();
    if (FAILED(hr)) {
        logOnce("SetDevice", hr);
        release(g.source);
        return 0;
    }
    g.sourceWidth = width;
    g.sourceHeight = height;
    return 1;
}

int32_t winvideo_draw_yuv(int32_t width, int32_t height, const uint8_t *y,
                          const uint8_t *u, const uint8_t *v,
                          const uint8_t *overlay_bgra) {
    if (!g.device || !g.source || !y || !u || !v) return 0;
    if (width <= 0 || height <= 0) return 0;
    if (!ensureTextures(width, height)) return 0;

    const int cw = (width + 1) / 2;
    const int ch = (height + 1) / 2;
    if (!uploadPlane(g.texY, y, width, width, height, 1)) return 0;
    if (!uploadPlane(g.texU, u, cw, cw, ch, 1)) return 0;
    if (!uploadPlane(g.texV, v, cw, cw, ch, 1)) return 0;
    const bool hasOverlay = overlay_bgra != nullptr;
    if (hasOverlay) {
        if (!uploadPlane(g.texOverlay, overlay_bgra, width * 4, width, height, 4))
            return 0;
    }

    ID3D11RenderTargetView *rtv = nullptr;
    POINT offset = {};
    RECT rect = {};
    if (!beginTarget(&rtv, &offset, &rect)) return 0;

    D3D11_VIEWPORT vp = {};
    vp.TopLeftX = (FLOAT)offset.x;
    vp.TopLeftY = (FLOAT)offset.y;
    vp.Width = (FLOAT)(rect.right - rect.left);
    vp.Height = (FLOAT)(rect.bottom - rect.top);
    vp.MaxDepth = 1.0f;

    ID3D11ShaderResourceView *srvs[4] = {g.srvY, g.srvU, g.srvV, g.srvOverlay};
    setParams(hasOverlay);

    g.context->OMSetRenderTargets(1, &rtv, nullptr);
    g.context->RSSetViewports(1, &vp);
    g.context->VSSetShader(g.vs, nullptr, 0);
    g.context->PSSetShader(g.ps, nullptr, 0);
    g.context->PSSetShaderResources(0, 4, srvs);
    g.context->PSSetSamplers(0, 1, &g.sampler);
    g.context->PSSetConstantBuffers(0, 1, &g.params);
    g.context->IASetInputLayout(nullptr);
    g.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    g.context->Draw(4, 0);

    // Unbind before EndDraw: the atlas surface goes back to XAML and leaving it
    // set as a render target is how you get a driver complaining about a
    // resource still bound for output.
    ID3D11RenderTargetView *none = nullptr;
    g.context->OMSetRenderTargets(1, &none, nullptr);
    release(rtv);

    HRESULT hr = g.source->EndDraw();
    if (FAILED(hr)) {
        if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
            g.deviceLost = true;
        }
        logOnce("EndDraw", hr);
        return 0;
    }
    return 1;
}

int32_t winvideo_device_lost(void) { return g.deviceLost ? 1 : 0; }

int32_t winvideo_clear(void) {
    ID3D11RenderTargetView *rtv = nullptr;
    POINT offset = {};
    RECT rect = {};
    if (!beginTarget(&rtv, &offset, &rect)) return 0;
    const FLOAT black[4] = {0, 0, 0, 1};
    g.context->ClearRenderTargetView(rtv, black);
    ID3D11RenderTargetView *none = nullptr;
    g.context->OMSetRenderTargets(1, &none, nullptr);
    release(rtv);
    HRESULT hr = g.source->EndDraw();
    if (FAILED(hr)) {
        logOnce("EndDraw(clear)", hr);
        return 0;
    }
    return 1;
}

void winvideo_reset(void) {
    releaseTextures();
    release(g.source);
    release(g.blend);
    release(g.params);
    release(g.sampler);
    release(g.ps);
    release(g.vs);
    release(g.context);
    release(g.device);
    g.sourceWidth = 0;
    g.sourceHeight = 0;
    g.deviceLost = false;
}

int32_t winvideo_selftest_check(int32_t width, int32_t height, const uint8_t *y,
                                const uint8_t *u, const uint8_t *v) {
    // Renders to an offscreen target rather than the bound source, so the check
    // needs no XAML at all — which is the point: it runs on a CI runner with no
    // desktop, under WARP.
    if (!g.device) return 0;
    if (!ensureTextures(width, height)) return 0;

    D3D11_TEXTURE2D_DESC td = {};
    td.Width = (UINT)width;
    td.Height = (UINT)height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *target = nullptr;
    if (FAILED(g.device->CreateTexture2D(&td, nullptr, &target))) return 0;

    ID3D11RenderTargetView *rtv = nullptr;
    if (FAILED(g.device->CreateRenderTargetView(target, nullptr, &rtv))) {
        target->Release();
        return 0;
    }

    const int cw = (width + 1) / 2, ch = (height + 1) / 2;
    uploadPlane(g.texY, y, width, width, height, 1);
    uploadPlane(g.texU, u, cw, cw, ch, 1);
    uploadPlane(g.texV, v, cw, cw, ch, 1);
    setParams(false);

    D3D11_VIEWPORT vp = {};
    vp.Width = (FLOAT)width;
    vp.Height = (FLOAT)height;
    vp.MaxDepth = 1.0f;
    ID3D11ShaderResourceView *srvs[4] = {g.srvY, g.srvU, g.srvV, g.srvOverlay};
    g.context->OMSetRenderTargets(1, &rtv, nullptr);
    g.context->RSSetViewports(1, &vp);
    g.context->VSSetShader(g.vs, nullptr, 0);
    g.context->PSSetShader(g.ps, nullptr, 0);
    g.context->PSSetShaderResources(0, 4, srvs);
    g.context->PSSetSamplers(0, 1, &g.sampler);
    g.context->PSSetConstantBuffers(0, 1, &g.params);
    g.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    g.context->Draw(4, 0);

    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *staging = nullptr;
    int ok = 0;
    ID3D11RenderTargetView *unbound = nullptr;
    if (SUCCEEDED(g.device->CreateTexture2D(&td, nullptr, &staging))) {
        // Unbind before every CopyResource: reading a resource that is still set
        // as a render target is what the debug layer exists to complain about.
        g.context->OMSetRenderTargets(1, &unbound, nullptr);
        g.context->CopyResource(staging, target);
        D3D11_MAPPED_SUBRESOURCE m = {};
        if (SUCCEEDED(g.context->Map(staging, 0, D3D11_MAP_READ, 0, &m))) {
            // Four bar centres: white, black, red, blue — asserted with the SAME
            // predicates `cgtkvideo_selftest_check` uses, deliberately, because
            // agreeing with the GL shader is the whole point of sharing
            // `ColorBars`.
            //
            // Predicates and not exact values with a tolerance. The first draft
            // of this function expected {235,235,235}/{16,16,16}/{235,16,16}/
            // {16,16,235} within ±24, which a CORRECT render fails: ColorBars'
            // third bar is Y=128,U=128,V=255, which is not saturated red but a
            // mid-luma high-Cr colour, and BT.709 puts it at rgb(255,63,130) —
            // 47 away from the expected green. The fourth lands at
            // rgb(130,103,255). Exact expectations would have made CI red and
            // invited "fixing" the shader to match a bad constant.
            //
            // Loose enough to survive both shaders' rounding, tight enough to
            // catch what actually breaks: a channel swap fails `r > b + 60` on
            // bar 2 and `b > r + 60` on bar 3.
            //
            // The GL version also checks a letterbox row. That is deliberately
            // absent here: this shader does no geometry — the surface is the
            // video's own size and XAML scales the element — so there is no
            // letterbox to find, and asserting one would fail by design.
            const uint8_t *rowAt = (const uint8_t *)m.pData;
            int bars[4][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
            for (int bar = 0; bar < 4; ++bar) {
                const int px = width * (2 * bar + 1) / 8;
                const int py = height / 2;
                const uint8_t *p = rowAt + (size_t)py * m.RowPitch + (size_t)px * 4;
                bars[bar][0] = p[2];  // R — the target is B8G8R8A8
                bars[bar][1] = p[1];  // G
                bars[bar][2] = p[0];  // B
                fprintf(stderr, "WINVIDEO_SELFTEST bar%d rgb=%d,%d,%d\n", bar,
                        bars[bar][0], bars[bar][1], bars[bar][2]);
            }
            const int white = bars[0][0] > 200 && bars[0][1] > 200 && bars[0][2] > 200;
            const int black = bars[1][0] < 60 && bars[1][1] < 60 && bars[1][2] < 60;
            const int red = bars[2][0] > 180 && bars[2][0] > bars[2][2] + 60;
            const int blue = bars[3][2] > 180 && bars[3][2] > bars[3][0] + 60;
            ok = white && black && red && blue;
            if (!ok) {
                fprintf(stderr,
                        "WINVIDEO_SELFTEST bars white=%d black=%d red=%d blue=%d\n",
                        white, black, red, blue);
            }
            g.context->Unmap(staging, 0);
        }

        // SECOND PASS — the overlay composite, which is where the two defects
        // that actually shipped lived, and neither was a build error:
        // the overlay texture was declared R8G8B8A8 while `AnnotationRasterizer`
        // writes b,g,r,a, and the shader multiplied by alpha a second time on
        // already-premultiplied data. One patch catches both.
        //
        // Half-transparent premultiplied red (b=0, g=0, r=128, a=128) laid over
        // the BLACK bar, whose own contribution is zero, so the sampled pixel is
        // the composite arithmetic and nothing else:
        //   correct        -> r = 128   (0*(1-.502) + .502)
        //   alpha twice    -> r =  64   (.502*.502) ............ fails r > 100
        //   channels swapped -> r = 0, b = 128 .................. fails r > b+60
        if (ok) {
            const size_t obytes = (size_t)width * height * 4;
            uint8_t *overlay = (uint8_t *)calloc(obytes, 1);
            if (!overlay) {
                ok = 0;
            } else {
                const int x0 = width / 4, x1 = width / 2;
                for (int row = 0; row < height; ++row) {
                    uint8_t *p = overlay + (size_t)row * width * 4;
                    for (int col = x0; col < x1; ++col) {
                        p[col * 4 + 0] = 0;    // B
                        p[col * 4 + 1] = 0;    // G
                        p[col * 4 + 2] = 128;  // R, premultiplied by a=128
                        p[col * 4 + 3] = 128;  // A
                    }
                }
                uploadPlane(g.texOverlay, overlay, width * 4, width, height, 4);
                uploadPlane(g.texY, y, width, width, height, 1);
                uploadPlane(g.texU, u, cw, cw, ch, 1);
                uploadPlane(g.texV, v, cw, cw, ch, 1);
                setParams(true);
                // Re-bind the views after the uploads. WRITE_DISCARD renames the
                // underlying allocation, so re-pointing the slots is the honest
                // thing to do rather than trusting the rename to carry through a
                // binding made before pass 1.
                ID3D11ShaderResourceView *srvs2[4] = {g.srvY, g.srvU, g.srvV,
                                                      g.srvOverlay};
                g.context->PSSetShaderResources(0, 4, srvs2);
                g.context->OMSetRenderTargets(1, &rtv, nullptr);
                g.context->RSSetViewports(1, &vp);
                g.context->Draw(4, 0);
                free(overlay);

                D3D11_MAPPED_SUBRESOURCE m2 = {};
                g.context->OMSetRenderTargets(1, &unbound, nullptr);
                g.context->CopyResource(staging, target);
                if (SUCCEEDED(g.context->Map(staging, 0, D3D11_MAP_READ, 0, &m2))) {
                    const int px = width * 3 / 8;  // centre of the black bar
                    const int py = height / 2;
                    const uint8_t *p =
                        (const uint8_t *)m2.pData + (size_t)py * m2.RowPitch + (size_t)px * 4;
                    const int b = p[0], gg = p[1], r = p[2];
                    fprintf(stderr, "WINVIDEO_SELFTEST overlay rgb=%d,%d,%d\n", r, gg, b);
                    const int bright = r > 100;
                    const int notSwapped = r > b + 60;
                    if (!bright || !notSwapped) {
                        fprintf(stderr,
                                "WINVIDEO_SELFTEST overlay premultiplied=%d "
                                "channel_order=%d\n",
                                bright, notSwapped);
                        ok = 0;
                    }
                    g.context->Unmap(staging, 0);
                } else {
                    ok = 0;
                }
            }
        }
        staging->Release();
    }
    fprintf(stderr, "WINVIDEO_SELFTEST result=%s\n", ok ? "PASS" : "FAIL");
    fflush(stderr);

    ID3D11RenderTargetView *none = nullptr;
    g.context->OMSetRenderTargets(1, &none, nullptr);
    rtv->Release();
    target->Release();
    return ok;
}

}  // extern "C"

#endif  // _WIN32

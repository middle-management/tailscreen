#include "include/portalcapture.h"

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/utils/result.h>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// The PipeWire half: turn the portal's (fd, node id) into a stream of packed
// BGRA frames.
//
// Three decisions in here are the ones that make or break this path, and none
// of them fails loudly if you get them wrong.
//
// 1. WE ASK ONLY FOR BGRx/BGRA. PipeWire will happily negotiate RGBx, YUY2 or
//    NV12 if we offer them, and then the buffer we hand upward is not what the
//    repo's shared `BGRAToI420` expects — the result is swapped channels or
//    garbage, not an error. Offering exactly the format the rest of the repo's
//    capture backends produce is what keeps this seam identical to Windows'.
//
// 2. WE ASK ONLY FOR MemPtr/MemFd BUFFERS. On a GPU compositor the producer
//    would rather hand us a DMA-BUF, and then `datas[0].data` is NULL and the
//    pixels live in GPU memory behind an EGL/GBM import we do not do. Not
//    constraining `dataType` gives a stream that connects, runs, and delivers
//    nothing but NULL pointers. Accepting the CPU-copy cost is a deliberate
//    first-increment choice; zero-copy DMA-BUF import is real work and belongs
//    with a GPU encoder, not here.
//
// 3. THE STREAM OWNS A THREAD. `pw_thread_loop` runs the stream's event loop
//    itself, so frames arrive on a thread of PipeWire's making and the
//    `CaptureEncoding` contract's "callbacks fire on whatever thread the
//    backend produces on" is satisfied without the host pumping anything. Every
//    pw_* call from outside that thread must hold the loop lock, which is what
//    the pw_thread_loop_lock pairs below are for.

struct ts_pwcap {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;

    ts_pwcap_frame_cb on_frame;
    ts_pwcap_state_cb on_state;
    void *user;

    // Written on the stream thread, read from anywhere. Atomic rather than
    // lock-guarded because the reader is a watchdog that wants a recent value,
    // not a consistent snapshot.
    _Atomic int width;
    _Atomic int height;
    _Atomic unsigned long long frames;

    struct spa_video_info format;
};

static void emit_state(ts_pwcap_t *c, int state, const char *detail) {
    if (c->on_state) c->on_state(c->user, state, detail ? detail : "");
}

static void on_stream_state_changed(void *data, enum pw_stream_state old,
                                    enum pw_stream_state state, const char *error) {
    (void)old;
    ts_pwcap_t *c = data;
    switch (state) {
        case PW_STREAM_STATE_ERROR:
            emit_state(c, TS_PWCAP_STATE_ERROR, error);
            break;
        case PW_STREAM_STATE_UNCONNECTED:
            // The producer went away. On a real desktop this is the user
            // clicking the compositor's own "stop sharing" button, which is a
            // normal end to a share and must not be reported as a crash.
            emit_state(c, TS_PWCAP_STATE_ENDED, "the capture source stopped");
            break;
        case PW_STREAM_STATE_STREAMING:
            emit_state(c, TS_PWCAP_STATE_STREAMING, NULL);
            break;
        default:
            emit_state(c, TS_PWCAP_STATE_CONNECTING, NULL);
            break;
    }
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    ts_pwcap_t *c = data;
    if (param == NULL || id != SPA_PARAM_Format) return;

    if (spa_format_parse(param, &c->format.media_type, &c->format.media_subtype) < 0) return;
    if (c->format.media_type != SPA_MEDIA_TYPE_video ||
        c->format.media_subtype != SPA_MEDIA_SUBTYPE_raw)
        return;
    if (spa_format_video_raw_parse(param, &c->format.info.raw) < 0) return;

    atomic_store(&c->width, (int)c->format.info.raw.size.width);
    atomic_store(&c->height, (int)c->format.info.raw.size.height);

    // Answer with the buffer constraints. See note 2 at the top: leaving
    // dataType unconstrained is what silently produces a DMA-BUF stream with
    // NULL data pointers.
    uint8_t buffer[512];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers, SPA_PARAM_BUFFERS_buffers,
        SPA_POD_CHOICE_RANGE_Int(4, 2, 8), SPA_PARAM_BUFFERS_dataType,
        SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    pw_stream_update_params(c->stream, params, 1);
}

static void on_process(void *data) {
    ts_pwcap_t *c = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(c->stream);
    if (b == NULL) return;

    struct spa_buffer *buf = b->buffer;
    do {
        if (buf->n_datas < 1) break;
        struct spa_data *d = &buf->datas[0];
        // NULL here means the negotiation escaped note 2 above — a DMA-BUF
        // arrived. Dropping the frame is right: there is nothing to read.
        if (d->data == NULL || d->chunk == NULL) break;
        if (d->chunk->size == 0) break;
        // A producer marks a buffer corrupted when it could not finish
        // writing it. Encoding it would put a torn frame on every viewer's
        // screen and hold it until the next keyframe.
        if (d->chunk->flags & SPA_CHUNK_FLAG_CORRUPTED) break;

        int width = atomic_load(&c->width);
        int height = atomic_load(&c->height);
        if (width <= 0 || height <= 0) break;

        // stride is authoritative when present and is routinely wider than
        // width*4; a producer that reports 0 is packed.
        int stride = d->chunk->stride > 0 ? (int)d->chunk->stride : width * 4;
        // Guard against believing a stride/size pair that would walk off the
        // end of the mapping — a malformed producer must not become a read
        // past the buffer.
        if ((int64_t)stride * height > (int64_t)d->maxsize) break;

        atomic_fetch_add(&c->frames, 1ull);
        if (c->on_frame)
            c->on_frame(c->user, (const uint8_t *)d->data + d->chunk->offset, stride, width,
                        height);
    } while (0);

    pw_stream_queue_buffer(c->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_stream_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

ts_pwcap_t *ts_pwcap_open(int pipewire_fd, uint32_t node_id, ts_pwcap_frame_cb on_frame,
                          ts_pwcap_state_cb on_state, void *user) {
    if (pipewire_fd < 0) return NULL;

    // Idempotent in libpipewire; safe to call per stream.
    pw_init(NULL, NULL);

    ts_pwcap_t *c = calloc(1, sizeof(*c));
    if (!c) {
        close(pipewire_fd);
        return NULL;
    }
    c->on_frame = on_frame;
    c->on_state = on_state;
    c->user = user;
    atomic_store(&c->width, 0);
    atomic_store(&c->height, 0);
    atomic_store(&c->frames, 0ull);

    c->loop = pw_thread_loop_new("ts-portal-capture", NULL);
    if (!c->loop) {
        close(pipewire_fd);
        free(c);
        return NULL;
    }

    pw_thread_loop_lock(c->loop);

    c->context = pw_context_new(pw_thread_loop_get_loop(c->loop), NULL, 0);
    if (!c->context) goto fail;

    // TAKES the fd: pw_context_connect_fd closes it when the core goes away,
    // whether or not it succeeded. Closing it ourselves as well is a double
    // close on an fd number the process may have reused.
    c->core = pw_context_connect_fd(c->context, pipewire_fd, NULL, 0);
    pipewire_fd = -1;
    if (!c->core) goto fail;

    c->stream = pw_stream_new(
        c->core, "tailscreen-screen-capture",
        pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                          PW_KEY_MEDIA_ROLE, "Screen", NULL));
    if (!c->stream) goto fail;
    pw_stream_add_listener(c->stream, &c->stream_listener, &stream_events, c);

    uint8_t builder_buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(builder_buffer, sizeof(builder_buffer));
    struct spa_rectangle size_default = SPA_RECTANGLE(1920, 1080);
    struct spa_rectangle size_min = SPA_RECTANGLE(1, 1);
    struct spa_rectangle size_max = SPA_RECTANGLE(16384, 16384);
    struct spa_fraction rate_default = SPA_FRACTION(60, 1);
    struct spa_fraction rate_min = SPA_FRACTION(0, 1);
    struct spa_fraction rate_max = SPA_FRACTION(240, 1);

    const struct spa_pod *params[1];
    // See note 1 at the top: BGRx and BGRA only. BGRx first, because a screen
    // capture has no meaningful alpha and the x form saves the producer a
    // premultiply.
    params[0] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType,
        SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
        SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
        SPA_POD_CHOICE_ENUM_Id(3, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
                               SPA_VIDEO_FORMAT_BGRA),
        SPA_FORMAT_VIDEO_size,
        SPA_POD_CHOICE_RANGE_Rectangle(&size_default, &size_min, &size_max),
        SPA_FORMAT_VIDEO_framerate,
        SPA_POD_CHOICE_RANGE_Fraction(&rate_default, &rate_min, &rate_max));

    int rc = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, node_id,
                               PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
                               params, 1);
    if (rc < 0) goto fail;

    pw_thread_loop_unlock(c->loop);
    if (pw_thread_loop_start(c->loop) < 0) {
        ts_pwcap_close(c);
        return NULL;
    }
    return c;

fail:
    pw_thread_loop_unlock(c->loop);
    if (pipewire_fd >= 0) close(pipewire_fd);
    ts_pwcap_close(c);
    return NULL;
}

void ts_pwcap_close(ts_pwcap_t *c) {
    if (!c) return;
    if (c->loop) {
        // Stop before touching anything the loop thread owns; pw_stream_destroy
        // from another thread while the loop is running is a use-after-free
        // waiting for the next process callback.
        pw_thread_loop_stop(c->loop);
    }
    if (c->stream) pw_stream_destroy(c->stream);
    if (c->core) pw_core_disconnect(c->core);
    if (c->context) pw_context_destroy(c->context);
    if (c->loop) pw_thread_loop_destroy(c->loop);
    free(c);
}

int ts_pwcap_size(ts_pwcap_t *c, int *width, int *height) {
    if (!c) return 0;
    int w = atomic_load(&c->width);
    int h = atomic_load(&c->height);
    if (w <= 0 || h <= 0) return 0;
    if (width) *width = w;
    if (height) *height = h;
    return 1;
}

uint64_t ts_pwcap_frame_count(ts_pwcap_t *c) {
    return c ? (uint64_t)atomic_load(&c->frames) : 0;
}

const char *ts_pwcap_library_version(void) { return pw_get_library_version(); }

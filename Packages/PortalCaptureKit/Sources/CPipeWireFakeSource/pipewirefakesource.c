#include "include/pipewirefakesource.h"

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// See the header for what this proves and what it deliberately does not.

#define TS_PWFAKE_PADDING 0x5A

struct ts_pwfake {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_source *timer;
    struct pw_proxy *link;

    ts_pwfake_config_t config;
    int stride;
    _Atomic unsigned long long frames;
    char error[192];
};

void ts_pwfake_expected_pixel(int x, int y, uint8_t out_bgra[4]) {
    // Three different functions of (x, y), so no single-axis mistake maps onto
    // a value this pattern also produces:
    //   blue  depends on x only
    //   green depends on y only   → a row read at the wrong pitch is wrong here
    //   red   depends on both     → red and blue can never be swapped unseen
    out_bgra[0] = (uint8_t)(x * 7 + 11);
    out_bgra[1] = (uint8_t)(y * 5 + 29);
    out_bgra[2] = (uint8_t)((x ^ y) * 3 + 71);
    out_bgra[3] = 0xFF;
}

uint8_t ts_pwfake_padding_byte(void) { return TS_PWFAKE_PADDING; }

static void set_error(ts_pwfake_t *f, const char *text) {
    snprintf(f->error, sizeof(f->error), "%s", text);
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    ts_pwfake_t *f = data;
    if (param == NULL || id != SPA_PARAM_Format) return;

    struct spa_video_info info;
    if (spa_format_parse(param, &info.media_type, &info.media_subtype) < 0) return;
    if (info.media_type != SPA_MEDIA_TYPE_video || info.media_subtype != SPA_MEDIA_SUBTYPE_raw)
        return;
    if (spa_format_video_raw_parse(param, &info.info.raw) < 0) return;

    f->stride = (int)info.info.raw.size.width * 4 + f->config.stride_padding;

    // Dictating both size and stride is what puts the padding on the wire. A
    // producer that leaves stride to the server gets width*4 and the consumer's
    // stride handling is then never exercised at all — the gate would pass
    // against a consumer that ignores stride entirely.
    uint8_t buffer[512];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers, SPA_PARAM_BUFFERS_buffers,
        SPA_POD_CHOICE_RANGE_Int(4, 2, 8), SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
        SPA_PARAM_BUFFERS_size, SPA_POD_Int(f->stride * (int)info.info.raw.size.height),
        SPA_PARAM_BUFFERS_stride, SPA_POD_Int(f->stride), SPA_PARAM_BUFFERS_dataType,
        SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    pw_stream_update_params(f->stream, params, 1);
}

static void on_process(void *data) {
    ts_pwfake_t *f = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(f->stream);
    if (b == NULL) return;

    struct spa_data *d = &b->buffer->datas[0];
    if (d->data == NULL || f->stride <= 0) {
        pw_stream_queue_buffer(f->stream, b);
        return;
    }
    int height = f->config.height;
    int width = f->config.width;
    if ((uint32_t)(f->stride * height) > d->maxsize) {
        set_error(f, "the negotiated buffer is smaller than stride * height");
        pw_stream_queue_buffer(f->stream, b);
        return;
    }

    uint8_t *pixels = d->data;
    // Poison first, pattern second: whatever is left poisoned is padding, and a
    // consumer reading at width*4 lands in it.
    memset(pixels, TS_PWFAKE_PADDING, (size_t)f->stride * (size_t)height);
    for (int y = 0; y < height; y++) {
        uint8_t *row = pixels + (size_t)y * (size_t)f->stride;
        for (int x = 0; x < width; x++) ts_pwfake_expected_pixel(x, y, row + x * 4);
    }

    d->chunk->offset = 0;
    // Three deliberate lies live here, each covering a consumer branch that is
    // otherwise only reachable from a buggy compositor.
    d->chunk->stride = f->config.corrupt_stride ? f->stride * 3 : f->stride;
    d->chunk->size = (uint32_t)(f->stride * height);
    d->chunk->flags = f->config.mark_corrupted ? SPA_CHUNK_FLAG_CORRUPTED : 0;
    atomic_fetch_add(&f->frames, 1ull);
    pw_stream_queue_buffer(f->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .param_changed = on_param_changed,
    .process = on_process,
};

static void on_timer(void *data, uint64_t expirations) {
    (void)expirations;
    ts_pwfake_t *f = data;
    // The producer is the graph's driver, so nothing else paces it. Without
    // this trigger the process callback is never called and the consumer waits
    // forever on a stream that is otherwise perfectly connected.
    pw_stream_trigger_process(f->stream);
}

int ts_pwfake_open_daemon_fd(void) {
    const char *dir = getenv("PIPEWIRE_RUNTIME_DIR");
    if (dir == NULL) dir = getenv("XDG_RUNTIME_DIR");
    if (dir == NULL) return -1;

    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if (snprintf(path, sizeof(path), "%s/pipewire-0", dir) >= (int)sizeof(path)) return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, strlen(path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

ts_pwfake_t *ts_pwfake_start(const ts_pwfake_config_t *config) {
    if (config == NULL || config->width <= 0 || config->height <= 0) return NULL;
    pw_init(NULL, NULL);

    ts_pwfake_t *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->config = *config;
    if (f->config.fps <= 0) f->config.fps = 30;
    set_error(f, "no error");

    f->loop = pw_thread_loop_new("ts-pwfake", NULL);
    if (!f->loop) goto fail;

    pw_thread_loop_lock(f->loop);
    f->context = pw_context_new(pw_thread_loop_get_loop(f->loop), NULL, 0);
    if (!f->context) goto fail_locked;
    f->core = pw_context_connect(f->context, NULL, 0);
    if (!f->core) {
        pw_thread_loop_unlock(f->loop);
        set_error(f, "no pipewire daemon (is one running, and is XDG_RUNTIME_DIR set?)");
        ts_pwfake_stop(f);
        return NULL;
    }

    f->stream = pw_stream_new(
        f->core, "ts-fake-screen-source",
        pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                          PW_KEY_MEDIA_ROLE, "Screen", PW_KEY_MEDIA_CLASS, "Video/Source", NULL));
    if (!f->stream) goto fail_locked;
    pw_stream_add_listener(f->stream, &f->stream_listener, &stream_events, f);

    uint8_t builder_buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(builder_buffer, sizeof(builder_buffer));
    struct spa_rectangle size = SPA_RECTANGLE((uint32_t)f->config.width, (uint32_t)f->config.height);
    struct spa_fraction rate = SPA_FRACTION((uint32_t)f->config.fps, 1);
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType,
        SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
        SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
        SPA_POD_Id(f->config.offer_rgbx_only ? SPA_VIDEO_FORMAT_RGBx : SPA_VIDEO_FORMAT_BGRx),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&size), SPA_FORMAT_VIDEO_framerate,
        SPA_POD_Fraction(&rate));

    // DRIVER because nothing else in this graph drives it: a screen-capture
    // producer paces the graph off its own clock, which is also what a
    // compositor's node does.
    if (pw_stream_connect(f->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                          PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_DRIVER, params, 1) < 0)
        goto fail_locked;

    f->timer = pw_loop_add_timer(pw_thread_loop_get_loop(f->loop), on_timer, f);
    struct timespec interval = {0, 1000000000L / f->config.fps};
    pw_loop_update_timer(pw_thread_loop_get_loop(f->loop), f->timer, &interval, &interval, false);
    pw_thread_loop_unlock(f->loop);

    if (pw_thread_loop_start(f->loop) < 0) {
        set_error(f, "could not start the producer's loop");
        ts_pwfake_stop(f);
        return NULL;
    }
    return f;

fail_locked:
    pw_thread_loop_unlock(f->loop);
fail:
    set_error(f, "could not build the fake producer");
    ts_pwfake_stop(f);
    return NULL;
}

uint32_t ts_pwfake_node_id(ts_pwfake_t *f) {
    if (!f || !f->loop || !f->stream) return 0;
    pw_thread_loop_lock(f->loop);
    uint32_t id = pw_stream_get_node_id(f->stream);
    pw_thread_loop_unlock(f->loop);
    return id == PW_ID_ANY ? 0 : id;
}

int ts_pwfake_link_to(ts_pwfake_t *f, uint32_t consumer_node_id) {
    if (!f || !f->core) return -1;
    uint32_t producer = ts_pwfake_node_id(f);
    if (producer == 0 || consumer_node_id == 0) {
        set_error(f, "cannot link before both nodes exist");
        return -1;
    }
    char output[16];
    char input[16];
    snprintf(output, sizeof(output), "%u", producer);
    snprintf(input, sizeof(input), "%u", consumer_node_id);

    pw_thread_loop_lock(f->loop);
    struct pw_properties *properties = pw_properties_new(
        "link.output.node", output, "link.input.node", input, "object.linger", "false", NULL);
    f->link = pw_core_create_object(f->core, "link-factory", PW_TYPE_INTERFACE_Link,
                                    PW_VERSION_LINK, &properties->dict, 0);
    pw_properties_free(properties);
    pw_thread_loop_unlock(f->loop);
    if (!f->link) {
        set_error(f, "the daemon has no link-factory");
        return -1;
    }
    return 0;
}

uint64_t ts_pwfake_frames_produced(ts_pwfake_t *f) {
    return f ? (uint64_t)atomic_load(&f->frames) : 0;
}

const char *ts_pwfake_last_error(ts_pwfake_t *f) { return f ? f->error : "no producer"; }

void ts_pwfake_stop(ts_pwfake_t *f) {
    if (!f) return;
    if (f->loop) pw_thread_loop_stop(f->loop);
    if (f->link) pw_proxy_destroy(f->link);
    if (f->stream) pw_stream_destroy(f->stream);
    if (f->core) pw_core_disconnect(f->core);
    if (f->context) pw_context_destroy(f->context);
    if (f->loop) pw_thread_loop_destroy(f->loop);
    free(f);
}

#include <opus/opus.h>

// libopus's control calls (opus_encoder_ctl / opus_decoder_ctl) are variadic
// macros, which Swift can't call. Expose the one knob Tailscreen needs as a
// plain, non-variadic static-inline shim so it imports cleanly.
static inline int opuskit_encoder_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}

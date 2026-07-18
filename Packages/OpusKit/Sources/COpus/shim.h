// opus.pc's Cflags point -I *into* the opus/ header dir
// (-I<prefix>/include/opus), so the header is <opus.h>, not <opus/opus.h>.
// <opus/opus.h> only resolves on Linux because /usr/include is a default
// clang search path; Homebrew's /opt/homebrew/include is not, so the
// prefixed form fails to find the header on macOS. <opus.h> is correct on
// Linux, macOS (brew), and Windows (vcpkg) alike.
#include <opus.h>

// libopus's control calls (opus_encoder_ctl / opus_decoder_ctl) are variadic
// macros, which Swift can't call. Expose the one knob Tailscreen needs as a
// plain, non-variadic static-inline shim so it imports cleanly.
static inline int opuskit_encoder_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}

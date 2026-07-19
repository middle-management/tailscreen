// FFmpeg headers use the <libX/Y.h> include form; libavcodec.pc's -I points
// at the parent include dir, so these resolve on Linux (default path) and
// macOS/Windows (pkg-config -I) alike.
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <errno.h>

// AVERROR(...) and AVERROR_EOF are macros, which Swift can't evaluate. Expose
// the two the decode loop needs (EAGAIN = "send more input", EOF = "drained")
// as plain functions so the wrapper can compare `avcodec_receive_frame`'s
// return value against them.
static inline int ffk_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int ffk_averror_eof(void) { return AVERROR_EOF; }

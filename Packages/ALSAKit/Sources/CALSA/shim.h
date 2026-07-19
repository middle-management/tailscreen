// The single system header for libasound — the ALSA client library. It pulls
// in the PCM, control, mixer, and error interfaces. asoundlib.h lives at
// <alsa/asoundlib.h> on Linux (the only platform ALSA exists on): the alsa.pc
// Cflags point -I at the include prefix, so the prefixed form is correct and
// resolves against /usr/include's default clang search path.
#include <alsa/asoundlib.h>

// ALSA reports underruns/other transport faults as negative POSIX errno codes
// (e.g. `snd_pcm_writei` returns -EPIPE on an underrun). Those macros aren't
// reliably visible to Swift through Foundation alone, so expose the one the
// playback path branches on as a plain constant. Negated to match ALSA's
// return-value convention, so the Swift side can compare `frames == alsakit_EPIPE`.
static inline long alsakit_EPIPE(void) { return -EPIPE; }

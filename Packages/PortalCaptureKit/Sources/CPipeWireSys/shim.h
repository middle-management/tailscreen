#ifndef TS_CPIPEWIRESYS_SHIM_H
#define TS_CPIPEWIRESYS_SHIM_H

// libpipewire + libspa. Only the C targets include this. SPA's format helpers
// are macro-heavy enough that they are not worth exposing to Swift even if
// they imported cleanly, which is most of why CPortalCapture exists.
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

#endif

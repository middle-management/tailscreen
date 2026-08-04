// GLib/GDBus, as one header for SwiftPM's systemLibrary target.
//
// Only the C shim (`CGNotify`) includes these; nothing in Swift touches a
// GVariant. See `ts_gnotify.h` for why that split exists.
#include <gio/gio.h>
#include <glib.h>

#!/usr/bin/env python3
"""Encode one second of a 440 Hz sine with libopus and print the packets.

The sharer's OpusVoiceEncoder shape: 48 kHz, mono, one 20 ms frame (960
samples) per packet, OPUS_APPLICATION_AUDIO. Written as base64 JSON for
audio.test.mjs, which feeds them to the page's AudioPath. ctypes over the
system libopus (the same library the apps link) so the test needs no Python
package and no encoder CLI.
"""
import ctypes, json, math, base64, sys
lib = ctypes.CDLL("libopus.so.0")
lib.opus_encoder_create.restype = ctypes.c_void_p
lib.opus_encoder_create.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
lib.opus_encode.restype = ctypes.c_int
lib.opus_encode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int16), ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
OPUS_APPLICATION_AUDIO = 2049
err = ctypes.c_int()
enc = lib.opus_encoder_create(48000, 1, OPUS_APPLICATION_AUDIO, ctypes.byref(err))
assert err.value == 0 and enc, err.value
packets = []
for i in range(50):
    pcm = (ctypes.c_int16 * 960)(*[int(12000 * math.sin(2 * math.pi * 440 * (i * 960 + n) / 48000)) for n in range(960)])
    out = ctypes.create_string_buffer(4000)
    n = lib.opus_encode(enc, pcm, 960, out, 4000)
    assert n > 0, n
    packets.append(base64.b64encode(out.raw[:n]).decode())
out = sys.stdout if len(sys.argv) < 2 or sys.argv[1] == "-" else open(sys.argv[1], "w")
json.dump(packets, out)

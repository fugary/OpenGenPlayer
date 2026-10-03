#!/usr/bin/env python3
"""Headless VLC rate regression: synthetic frames and audio stay in memory.

Requires a native build with tests/amem-clock.patch (test sink only) and the AVI,
rawvideo, araw, vmem, scaletempo, audio_format, mixer and resampler modules.
Never use this test sink patch when building the shipping iOS framework.
"""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import struct
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("build", type=Path)
parser.add_argument("--cache-ms", type=int, default=3000)
parser.add_argument("--mode", choices=["normal", "all", "rapid"], default="normal")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
build = args.build.resolve()
W, H, FPS, N = 160, 96, 25, 3600


def chunk(tag, data):
    return tag + struct.pack("<I", len(data)) + data + (b"\0" if len(data) % 2 else b"")


def listing(tag, data):
    return chunk(b"LIST", tag + data)


def stream_header(kind, codec, scale, rate, length, buf, sample):
    return struct.pack("<4s4sIHHIIIIIIIIhhhh", kind, codec, 0, 0, 0, 0,
                       scale, rate, 0, length, buf, 0xffffffff, sample,
                       0, 0, W if kind == b"vids" else 0, H if kind == b"vids" else 0)


# Lossless frame IDs in Y/U and nonzero PCM let the test detect repeated frames
# and inserted silence. No user media, microphone or sound device is accessed.
path = Path(tempfile.gettempdir()) / "genplayer-vlc-rate-i420-pcm-v2.avi"
if not path.exists():
    frame_bytes = W * H * 3 // 2
    avih = struct.pack("<14I", 40000, frame_bytes * FPS + 96000, 0, 0x10,
                       N, 0, 2, frame_bytes, W, H, 0, 0, 0, 0)
    video = chunk(b"strh", stream_header(b"vids", b"I420", 1, FPS, N, frame_bytes, 0))
    video += chunk(b"strf", struct.pack("<IiiHHIIiiII", 40, W, H, 1, 12,
                   int.from_bytes(b"I420", "little"), frame_bytes, 0, 0, 0, 0))
    audio = chunk(b"strh", stream_header(b"auds", b"\0" * 4, 2, 96000, N * 1920, 3840, 2))
    audio += chunk(b"strf", struct.pack("<HHIIHH", 1, 1, 48000, 96000, 2, 16))
    movi, index = bytearray(), bytearray()
    for frame in range(N):
        pixels = bytes([frame % 256]) * (W * H)
        pixels += bytes([frame // 256]) * (W * H // 4) + bytes([128]) * (W * H // 4)
        for tag, data in [(b"00db", pixels), (b"01wb", struct.pack("<h", 1000 + 5 * frame) * 1920)]:
            index += struct.pack("<4sIII", tag, 16, len(movi) + 4, len(data))
            movi += chunk(tag, data)
    body = b"AVI " + listing(b"hdrl", chunk(b"avih", avih) + listing(b"strl", video) + listing(b"strl", audio))
    body += listing(b"movi", movi) + chunk(b"idx1", index)
    path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)

os.environ["VLC_PLUGIN_PATH"] = str(build / "modules/.libs")
os.environ["GENPLAYER_VLC_TEST_CLOCK"] = "1"
core = C.CDLL(str(build / "src/.libs/libvlccore.dylib"), mode=C.RTLD_GLOBAL)
lib = C.CDLL(str(build / "lib/.libs/libvlc.dylib"))
ptr, integer, uint, tick, string = C.c_void_p, C.c_int, C.c_uint, C.c_int64, C.c_char_p


def bind(name, result, *arguments):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, list(arguments)
    return fn


clock = bind("libvlc_clock", tick)
new = bind("libvlc_new", ptr, integer, C.POINTER(string))
options = [b"--quiet", b"--vout=vmem", b"--aout=amem", b"--no-osd",
           b"--no-sub-autodetect-file", b"--no-media-library", b"--no-plugins-cache",
           b"--clock-jitter=0", b"--clock-synchro=0", f"--file-caching={args.cache_ms}".encode()]
instance = new(len(options), (string * len(options))(*options))
assert instance
media = bind("libvlc_media_new_path", ptr, ptr, string)(instance, str(path).encode())
player = bind("libvlc_media_player_new_from_media", ptr, ptr)(media)
bind("libvlc_media_release", None, ptr)(media)
audio_play = C.CFUNCTYPE(None, ptr, ptr, uint, tick)
event = C.CFUNCTYPE(None, ptr, tick)
single = C.CFUNCTYPE(None, ptr)
video_lock = C.CFUNCTYPE(ptr, ptr, C.POINTER(ptr))
video_unlock = C.CFUNCTYPE(None, ptr, ptr, C.POINTER(ptr))
video_display = C.CFUNCTYPE(None, ptr, ptr)
# The simple libVLC format API sets the same pitch for all planes.
pixels = (C.c_ubyte * (3 * W * H))()
audio, video, flushes, zeroes, underflows, changes = [], [], [], [], [], []
queue_end = None


@audio_play
def on_audio(opaque, data, count, pts):
    global queue_end
    if not count:
        return
    now = clock()
    if queue_end is not None and now > queue_end + 5000:
        underflows.append((now, now - queue_end))
    start = pts if queue_end is None else max(queue_end, now)
    queue_end = start + count * 1000000 / 48000
    audio.append((now, pts, count))
    if not any(C.string_at(data, count * 2)):
        zeroes.append((now, count))


@event
def on_event(opaque, pts):
    pass


@single
def on_flush(opaque):
    global queue_end
    flushes.append(clock())
    queue_end = None


@single
def on_drain(opaque):
    pass


@video_lock
def on_lock(opaque, planes):
    for plane in range(3):
        planes[plane] = C.addressof(pixels) + plane * W * H
    return None


@video_unlock
def on_unlock(opaque, picture, planes):
    pass


@video_display
def on_display(opaque, picture):
    video.append((clock(), pixels[0] + pixels[W * H] * 256))


bind("libvlc_audio_set_callbacks", None, ptr, audio_play, event, event, single, single, ptr)(
    player, on_audio, on_event, on_event, on_flush, on_drain, None)
bind("libvlc_audio_set_format", None, ptr, string, uint, uint)(player, b"S16N", 48000, 1)
bind("libvlc_video_set_callbacks", None, ptr, video_lock, video_unlock, video_display, ptr)(
    player, on_lock, on_unlock, on_display, None)
bind("libvlc_video_set_format", None, ptr, string, uint, uint, uint)(player, b"I420", W, H, W)
schedule = [(3.5, rate) for rate in [2, 1, 1.5, 1]]
if args.mode == "all":
    schedule = [(3.5, rate) for speed in [.5, .75, 1.25, 1.5, 2, 2.5, 3, 4] for rate in [speed, 1]]
elif args.mode == "rapid":
    schedule = [(3.5, 2), (.04, 1), (.04, 1.5), (.04, 1), (3.5, .5), (3.5, 2), (.04, 1)]
set_rate = bind("libvlc_media_player_set_rate", integer, ptr, C.c_float)
start = clock()
assert bind("libvlc_media_player_play", integer, ptr)(player) == 0
try:
    for wait, rate in schedule:
        time.sleep(wait)
        changes.append((clock(), rate))
        assert set_rate(player, rate) == 0
    time.sleep(3.5)
finally:
    end = clock()
    bind("libvlc_media_player_stop", None, ptr)(player)
    bind("libvlc_media_player_release", None, ptr)(player)
    bind("libvlc_release", None, ptr)(instance)

# Display callbacks can repeat the same image, concealing a visible freeze.
frames = [frame for i, frame in enumerate(video) if i == 0 or frame[1] != video[i - 1][1]]
gaps = [(b[0] - a[0]) / 1000 for a, b in zip(frames, frames[1:]) if b[0] >= changes[0][0]]
playback_flushes = [at for at in flushes if start < at < end]
result = dict(mode=args.mode, cache_ms=args.cache_ms, audio=audio, video=video,
              changes=changes, zeroes=zeroes, underflows=underflows,
              playback_flushes=playback_flushes, max_frame_gap_ms=max(gaps, default=0))
args.output.write_text(json.dumps(result))
print(f"{args.mode}, cache {args.cache_ms} ms: {len(frames)} distinct frames, "
      f"max gap {max(gaps, default=0):.1f} ms; {len(zeroes)} silence blocks, "
      f"{len(playback_flushes)} flushes, {len(underflows)} audio underflows")
assert len(frames) > 100 and len(audio) > 100, "Missing memory outputs"
assert not zeroes and not playback_flushes and not underflows, "Audio discontinuity"
assert max(gaps) < 180, "Video freeze (test source is 25 fps, slowest rate 0.5x)"

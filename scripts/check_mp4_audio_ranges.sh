#!/bin/bash
# Pure file checks. Does not start an app, simulator, playback or speech recognition.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
ffmpeg_bin="${GENPLAYER_FFMPEG:-$(command -v ffmpeg || true)}"
if [[ -z "$ffmpeg_bin" && -x /Applications/EmbyServer.app/Contents/MacOS/ffmpeg ]]; then
    ffmpeg_bin=/Applications/EmbyServer.app/Contents/MacOS/ffmpeg
fi
if [[ ! -x "$ffmpeg_bin" ]]; then
    echo 'Set GENPLAYER_FFMPEG to an FFmpeg executable to generate test media.' >&2
    exit 1
fi
ffprobe_bin="${GENPLAYER_FFPROBE:-$(dirname "$ffmpeg_bin")/ffprobe}"
if [[ ! -x "$ffprobe_bin" ]]; then
    ffprobe_bin="$(command -v ffprobe || true)"
fi
if [[ ! -x "$ffprobe_bin" ]]; then
    echo 'Set GENPLAYER_FFPROBE to an FFprobe executable to inspect reference track durations.' >&2
    exit 1
fi
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerMP4Fixtures.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
"$ffmpeg_bin" -v error -y -f lavfi -i 'testsrc2=size=640x360:rate=25:duration=65.25' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=65.25' \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=65.25' \
    -map 0:v -map 1:a -map 2:a -c:v mpeg4 -q:v 3 -c:a aac -b:a 128k \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn "$fixture_dir/tail.mp4"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" -map 0 -c copy -movflags +faststart "$fixture_dir/head.mp4"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" -map 0 -c copy -c:a:0 ac3 -b:a:0 192k "$fixture_dir/ac3-first.mp4"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" -map 0 -c copy -c:a:1 ac3 -b:a:1 192k "$fixture_dir/ac3-last.mp4"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" -map 0 -c copy -c:a ac3 -b:a 192k "$fixture_dir/ac3-only.mp4"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" -map 0:v -map 0:a:0 \
    -c:v copy -c:a aac -ar 44100 -b:a 128k "$fixture_dir/rate44100.mp4"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/rate44100.mp4" -ss 28 -t 34 -map 0:a:0 \
    -f f32le -ar 16000 -ac 1 "$fixture_dir/reference-rate44100-16000.f32"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" -ss 28 -t 34 -map 0:a:0 \
    -f f32le -ar 16000 -ac 1 "$fixture_dir/reference-tail-16000.f32"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" -map 0 -c copy \
    -movflags frag_keyframe+empty_moov "$fixture_dir/fragmented.mp4"
# A changing waveform detects time shifts that a periodic sine could conceal.
"$ffmpeg_bin" -v error -y -i "$fixture_dir/tail.mp4" \
    -f lavfi -i 'aevalsrc=0.15*sin(2*PI*(200*t+20*t*t))+0.08*sin(2*PI*(110*t+9*t*t)):s=48000:d=65.25' \
    -map 0:v -map 1:a -c:v copy -c:a aac -b:a 128k "$fixture_dir/compatibility.mp4"
"$ffmpeg_bin" -v error -y -i "$fixture_dir/compatibility.mp4" -itsoffset 2 -i "$fixture_dir/compatibility.mp4" \
    -map 0:v -map 1:a -c copy "$fixture_dir/delayed.mp4"
python3 - "$fixture_dir" <<'PY'
from pathlib import Path
import struct, sys
root = Path(sys.argv[1]); data = (root / 'tail.mp4').read_bytes()
def boxes(data):
    offset = 0
    while offset < len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        assert size >= 8 and offset + size <= len(data)
        yield kind, data[offset + 8:offset + size]
        offset += size
def atom(kind, body): return struct.pack('>I4s', len(body) + 8, kind) + body
def convert(data):
    result = bytearray()
    for kind, body in boxes(data):
        if kind in [b'moov', b'trak', b'mdia', b'minf', b'stbl']: body = convert(body)
        if kind == b'stco':
            kind = b'co64'
            body = body[:8] + b''.join(struct.pack('>Q', struct.unpack_from('>I', body, i)[0]) for i in range(8, len(body), 4))
        result += atom(kind, body)
    return bytes(result)
# moov is at the tail, so widening offsets does not move any media payload.
(root / 'co64.mp4').write_bytes(convert(data))
for name, key, relative, value in [('bad-offset', b'stco', 12, 0xffffffff), ('bad-count', b'stsz', 12, 0xffffffff)]:
    changed = bytearray(data); index = data.rindex(key)
    struct.pack_into('>I', changed, index + relative, value)
    (root / (name + '.mp4')).write_bytes(changed)
(root / 'encrypted.mp4').write_bytes(data.replace(b'mp4a', b'enca'))
(root / 'bad-roll.mp4').write_bytes(data.replace(b'sgpd', b'free'))
(root / 'implicit-delay.mp4').write_bytes((root / 'compatibility.mp4').read_bytes().replace(b'sgpd', b'free').replace(b'sbgp', b'free'))
implicit = (root / 'implicit-delay.mp4').read_bytes()
(root / 'no-edits.mp4').write_bytes(implicit.replace(b'edts', b'free'))
zero = bytearray(implicit)
# Fixture elst atoms are version 0, with a single edit. Keep lengths and set media time to zero.
position = 0
while True:
    position = zero.find(b'elst', position)
    if position < 0: break
    assert zero[position + 4] == 0 and struct.unpack_from('>I', zero, position + 8)[0] == 1
    struct.pack_into('>I', zero, position + 16, 0)
    position += 4
(root / 'zero-edit.mp4').write_bytes(zero)
(root / 'truncated.mp4').write_bytes(data[:-13])
PY
for name in implicit-delay no-edits zero-edit delayed; do
    # Preserve the movie timeline, including a leading empty edit and silence after audio ends.
    # FFmpeg emits full last AAC packets; apply its reported track end before padding.
    audio_end="$("$ffprobe_bin" -v error -select_streams a:0 -show_entries stream=start_time,duration \
        -of json "$fixture_dir/$name.mp4" | python3 -c 'import json,sys; s=json.load(sys.stdin)["streams"][0]; print(float(s["start_time"])+float(s["duration"]))')"
    "$ffmpeg_bin" -v error -y -i "$fixture_dir/$name.mp4" -map 0:a:0 \
        -af "aresample=48000:async=1:first_pts=0,atrim=end=$audio_end,apad" -t 70 -ac 1 -f f32le "$fixture_dir/reference-$name.f32"
done
bash "$repo_dir/scripts/check_audio_subtitles.sh" --mp4-fixtures "$fixture_dir"

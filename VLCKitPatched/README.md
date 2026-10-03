# GenPlayer iOS VLC rate fix

This package keeps the VLCKitSPM import and API. Its iOS framework is built from
VLCKit 3.7.3 (`319ed2c0724e3d4c4d34889a62fef1ae269491bc`) and its pinned VLC
3.0.23 core (`79128878ddb2c280bbb6c89c76a46b31a80ade1c`). The original macOS and
tvOS slices are copied without modification from the 3.7.3 binary distribution.

`patches/0001-continuous-rate.patch` preserves the end of queued audio when
changing rate. It includes the rate-scaled caching delay, retains the existing
clock behavior without active audio, and resets the anchor on seek/discontinuity.
Video and subtitle timestamps before each queued-audio boundary retain their
previous rate mapping. Applying the newest rate retroactively to those frames
would freeze video on acceleration even though audio stays continuous. Pending
transitions are retained across rapid changes and pause/origin adjustments;
expired mappings are pruned and resets discard them.
Hard audio flush/silence thresholds retain their normal-speed minimum because
output timestamps and tempo-filter windows are measured in wall-clock time.
The normal resampling thresholds remain unchanged.

Before opening/building the project on a fresh checkout, run:

```sh
python3 scripts/build_vlckit_rate_fix.py
```

This downloads pinned upstream sources, applies VLCKit's existing patches and
the local patch, builds unsigned iOS 15+ device/simulator frameworks, verifies
the original distribution checksum, and assembles `Artifacts/VLCKit-all.xcframework`.
Generated sources/binaries are ignored by Git. It does not launch an app or
simulator. An existing unmodified 3.7.3 artifact can be supplied with
`--base-xcframework /absolute/path/VLCKit-all.xcframework` to avoid downloading it.
Use a new `--work-dir` after changing the patch; unmarked build folders are never
overwritten. Keep the source, patch and LGPL license available with distribution.
The release preparation script calls `--ensure` before building, so its existing
local and GitHub Actions entry points also prepare this dependency when needed.

Headless clock/audio/video tests cover rate changes and output continuity; they do not
replace iOS device checks for audiovisual synchronization, seeking, tracks or PiP.
For a native macOS source build of the patched core, the clock regression runs as
`bash scripts/check_vlc_rate_clock.sh /path/to/vlc/source /path/to/native/build`.
It covers every menu speed, queued video before and across multiple rate
boundaries, subtitle spans, repeated changes without a new PCR, pause/resume,
clock-origin shifts and reset equivalence with a fresh clock.

For playback regression, use a separate native source/build tree. Apply
`tests/amem-clock.patch` there and rebuild its `amem` module to emulate an audio
device queue entirely in memory. This test-only patch is never applied by the
iOS framework builder. Build the AVI, rawvideo, araw, vmem, scaletempo,
audio_format, mixer and resampler modules, then run:

```sh
python3 VLCKitPatched/tests/playback.py /path/to/native/build \
    --mode all --cache-ms 3000 --output /tmp/vlc-rate-all.json
python3 VLCKitPatched/tests/playback.py /path/to/native/build \
    --mode rapid --cache-ms 1200 --output /tmp/vlc-rate-rapid.json
```

The test generates a lossless I420/PCM clip, routes video/audio to memory, and
checks distinct-frame gaps, inserted silence, audio flushes and queue starvation.
Counting display callbacks alone is insufficient: VLC repeats the same image
during a freeze. Neither test opens a window, simulator or sound device.

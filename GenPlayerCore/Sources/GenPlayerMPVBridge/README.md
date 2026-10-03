# Apple MPVKit rendering adapters

Pinned to **MPVKit 1.0.0 / mpv 0.41.0**. This is an internal mpv context adapter,
not a general stable libmpv API. Revalidate its ABI and static archive extraction
when upgrading MPVKit; do not upgrade the package independently.

`MetalContext.m` derives from MPVKit 1.0.0's
`Sources/BuildScripts/patch/libmpv/0001-player-add-moltenvk-context.patch`.
The original driver reconfigures only on video changes and ignores all window
control events. MoltenVK can resize the swapchain while gpu-next retains the
old destination/OSD rectangles, producing an upper-left partial-size picture.

The replacement publishes pixel geometry through a locked CAMetalLayer subclass
and wakes the VO thread. `VOCTRL_CHECK_EVENTS` calls `ra_vk_ctx_resize`, then emits
`VO_EVENT_RESIZE | VO_EVENT_EXPOSE` so gpu-next recomputes video/subtitle rectangles
and redraws even while paused. The UI never changes a live `drawableSize`.
Teardown clears the borrowed VO pointer under the same lock as wakeup.

The bridge supplies the strong `ra_ctx_vulkan_moltenvk` symbol before the static
Libmpv archive is searched; therefore its original context object is not loaded.
Swift calls `GPMPVMetalContextRevision` to ensure the bridge object is linked.
This does not patch binary memory or disable Metal validation. GenPlayerShell's
dependency covers macOS, iOS and tvOS. The Swift engine retains the layer until
`mpv_terminate_destroy` completes.

## Sources and licenses

- `vendor/mpv`: unmodified header dependency closure from
  https://github.com/mpv-player/mpv/tree/v0.41.0, plus a minimal local `config.h`.
  `COPYING` is upstream's `Copyright` overview; `LICENSE.LGPL` is the full license.
  Keep individual file copyright/license notices.
- `vendor/vulkan` and `vendor/vk_video`: required headers and license files from
  https://github.com/KhronosGroup/Vulkan-Headers/tree/v1.4.335.
- libplacebo headers come directly from the pinned MPVKit framework, rather than
  a second vendored copy.
- The Objective-C translation unit disables Clang implicit modules because
  MPVKit's libplacebo umbrella also exposes platform-specific Windows headers.
  The public bridge module exports the layer/revision and secondary ASS geometry APIs.

## Validation

- `bash scripts/check_mac_mpv_resize.sh <macOS Build/Products/Debug>` compiles the
  actual event handler with fake Vulkan/VO functions. It checks initial/Retina/
  shrinking/fullscreen geometry, coalescing, failed-resize retry, invalid sizes,
  wakeup without frames, and teardown. It creates no window and renders no media.
- `python3 scripts/check_mac_mpv_linking.py '<Gen Player.app>'` checks the built
  Debug/Release binary for the replacement and MPVKit/VLC dependency isolation.
- arm64 private-field offsets were checked against the original archive's
  `video_out_vulkan_context_moltenvk.m.o` and `video_out_vulkan_context.c.o`;
  the arm64 iOS and tvOS archive objects have the same adapter field offsets
  (`priv=0x50`, `log=0x18`, `vo.opts=0xe0`, `WinID=0x120`,
  `vo.dwidth=0xf8`, Vulkan context size `0x30`). Compile-time assertions
  prevent accidental header-configuration drift. UIKit integration is initially
  enabled only in the iOS player; tvOS still uses VLC.
- Real Metal rendering, fullscreen transitions, HDR, subtitle positioning, and
  moving between screens still require approved app-based verification.

## Native second ASS layer

`NativeASSRenderer.m` is `sub/sd_ass.c` from the same mpv v0.41.0 tag,
with its original LGPL license. Local changes are framework include paths,
ABI assertions, a revision symbol, selecting BGRA packing for the opted-in
second slot, one post-copy geometry callback, and native same-track mirroring. It supplies `sd_ass` and the
other symbols from that archive object, using the same static-link replacement
as the Metal context. `GPMPVSetSecondaryASS` references its revision to pull it in.
Primary subtitles and non-opted-in players retain the upstream path.

`NativeASSGeometry.m` keeps per-player bounds, anchor, size and position under a
mutex. Only copied bitmap destination rectangles change; masks, timing and ASS
content are untouched. BGRA packing is necessary: mpv's A8/LIBASS software
compositor does not support scaled/unclipped destinations. Bounds are normalized
to the actual output viewport (including any black bars), then mapped to the UI.
Empty cues retain the previous hit region; disabling/changing tracks clears state,
and engine teardown removes it. Scaling operates on the rasterized second layer,
so enlarged text can be softer. A changed, ASS-ignored secondary position option
requests paused redraws because mpv suppresses notifications for equal values.
No pixel readback, file access, or network work is added to the render loop.

For an iOS/macOS same-track ASS selection, mpv still owns just one subtitle
decoder. A second libass renderer shares that decoder's authored track and font
library, with an independent timestamp/layout cache. Both BGRA atlases are
combined after applying geometry only to the second layer. Unchanged paused
frames reuse the combined atlas; empty cues and enable/disable transitions
invalidate it. No downloadable subtitle copy or stripped-text overlay is needed.
The engine enables this bridge state only on iOS/macOS. Ordinary text mirrors,
distinct tracks and tvOS retain their existing paths.

- `bash scripts/check_mpv_secondary_ass_mirror.sh <macOS Build/Products/Debug>`
  exercises the production renderer with real libass and in-memory vector ASS.
  It checks equal glyph pixels, independent delay, scale/position isolation,
  paused reuse, gaps, returning to cues and disabling the mirror under sanitizers.
  It creates no player instance, window, media connection or screen capture.
- `bash scripts/check_mpv_secondary_ass.sh` checks production geometry with fake
  player identities and bitmap rectangles, under address/undefined sanitizers.
  It launches no application, simulator, renderer or media.
- `scripts/check_mac_mpv_linking.py` also requires the ASS descriptor, replacement
  revision, and geometry API in the final application binary.
- Revalidate the private ABI, upstream filters, `sd_ass` object extraction, all
  three Apple builds, and software/GPU subtitle output on MPVKit upgrades.
  Actual glyph/frame alignment, paused dragging, effects, HDR, and PiP require
  approved app verification; headless checks are not that acceptance.

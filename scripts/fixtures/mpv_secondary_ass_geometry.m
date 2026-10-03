// Headless tests of the production bridge; no mpv instance, window, or media.
#import "../../GenPlayerCore/Sources/GenPlayerMPVBridge/NativeASSGeometry.m"
#include <assert.h>
#include <stdio.h>

struct mpv_global *mp_client_get_global(struct mpv_handle *handle) { return (void *)handle; }
const char *GPMPVASSRendererRevision(void) { return "fixture"; }
static int checks;
#define CHECK(x) do { assert(x); checks++; } while (0)
static bool closeTo(double a, double b) { return fabs(a-b) < 0.002; }
static struct mp_osd_res viewport = {.w = 1000, .h = 500, .display_par = 1};
static struct sub_bitmaps cue(struct sub_bitmap *parts) {
    parts[0] = (struct sub_bitmap){.x=400, .y=350, .w=100, .h=20, .dw=100, .dh=20};
    parts[1] = (struct sub_bitmap){.x=500, .y=374, .w=100, .h=20, .dw=100, .dh=20};
    return (struct sub_bitmaps){.parts=parts, .num_parts=2, .format=SUBBITMAP_BGRA};
}
int main(void) {
    int identity1, identity2;
    void *handle = &identity1, *other = &identity2;
    struct sub_bitmap pieces[2];
    struct sub_bitmaps b = cue(pieces);
    CHECK(!GPMPVGetSecondaryASS(handle).hasBounds);
    GPMPVSetSecondaryASSMirror(handle, true);
    CHECK(!GPMPVMirrorsPrimaryASS(handle)); // Selection alone cannot enable rendering.
    GPMPVSetSecondaryASS(handle, 3, 1, -1);
    CHECK(GPMPVHasSecondaryASS(handle, 1));
    CHECK(GPMPVMirrorsPrimaryASS(handle) && !GPMPVMirrorsPrimaryASS(other));
    GPMPVSetSecondaryASSMirror(handle, false);
    CHECK(!GPMPVMirrorsPrimaryASS(handle));
    CHECK(!GPMPVHasSecondaryASS(handle, 0));
    GPMPVTransformSecondaryASS(handle, 0, handle, viewport, &b);
    CHECK(!GPMPVGetSecondaryASS(handle).hasBounds && pieces[0].x == 400);
    GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    GPMPVSecondaryASSGeometry g = GPMPVGetSecondaryASS(handle);
    CHECK(g.hasBounds && g.hasContent);
    CHECK(closeTo(g.bounds.origin.x, 0.4) && closeTo(g.bounds.origin.y, 0.7));
    CHECK(closeTo(g.bounds.size.width, 0.2) && closeTo(g.bounds.size.height, 0.088));
    CHECK(b.change_id == 1 && pieces[0].dw == 100);
    b = cue(pieces);
    GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    CHECK(b.change_id == 0); // An unchanged paused cue does not continually repaint.
    GPMPVSetSecondaryASS(handle, 3, 1.4, 0.3);
    b = cue(pieces);
    GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    g = GPMPVGetSecondaryASS(handle);
    CHECK(closeTo(CGRectGetMidY(g.bounds), 0.3));
    CHECK(pieces[0].dw == 140 && pieces[0].dh == 28);
    CHECK(pieces[0].w == 100 && pieces[0].h == 20); // Source glyph pixels unchanged.
    CHECK(closeTo(g.bounds.size.width, 0.28) && b.change_id == 1);
    b = cue(pieces); pieces[0].x += 20; pieces[1].x += 20;
    GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    CHECK(closeTo(CGRectGetMidX(GPMPVGetSecondaryASS(handle).bounds), 0.528)); // Animation preserved.
    struct sub_bitmaps empty = {0};
    GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &empty);
    g = GPMPVGetSecondaryASS(handle);
    CHECK(g.hasBounds && !g.hasContent); // Gap retains last hit region.
    GPMPVSetSecondaryASS(handle, 3, 1.4, 0.5);
    CHECK(closeTo(CGRectGetMidY(GPMPVGetSecondaryASS(handle).bounds), 0.5)); // Drag during gap.
    GPMPVSetSecondaryASS(other, 7, 1, 0.2);
    b = cue(pieces); GPMPVTransformSecondaryASS(other, 1, other, viewport, &b);
    CHECK(closeTo(CGRectGetMidY(GPMPVGetSecondaryASS(other).bounds), 0.2));
    CHECK(closeTo(CGRectGetMidY(GPMPVGetSecondaryASS(handle).bounds), 0.5));
    GPMPVSetSecondaryASS(handle, 8, 1, -1);
    CHECK(!GPMPVGetSecondaryASS(handle).hasBounds);
    b = cue(pieces); GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    CHECK(pieces[0].x == 400 && pieces[0].y == 350 && pieces[0].dw == 100);
    GPMPVSetSecondaryASS(handle, -1, 1, -1);
    CHECK(!GPMPVHasSecondaryASS(handle, 1) && !GPMPVGetSecondaryASS(handle).hasBounds);
    GPMPVSetSecondaryASS(handle, 9, NAN, INFINITY);
    b = cue(pieces); GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    CHECK(pieces[0].dw == 100 && pieces[0].y == 350);
    GPMPVSetSecondaryASS(handle, 10, 2, 0.1);
    b = cue(pieces); b.format = SUBBITMAP_LIBASS;
    GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    CHECK(pieces[0].x == 400 && pieces[0].dw == 100); // A8 race cannot move unsafe pixels.
    b = cue(pieces);
    GPMPVTransformSecondaryASS(handle, 1, handle, viewport, &b);
    CHECK(closeTo(CGRectGetMidY(GPMPVGetSecondaryASS(handle).bounds), 0.1));
    // Late output from the old decoder cannot anchor the newly selected decoder.
    b = cue(pieces); pieces[0].y -= 100; pieces[1].y -= 100;
    GPMPVTransformSecondaryASS(handle, 1, other, viewport, &b);
    CHECK(closeTo(CGRectGetMidY(GPMPVGetSecondaryASS(handle).bounds), 0.1));
    GPMPVClearSecondaryASS(handle);
    CHECK(!GPMPVGetSecondaryASS(handle).hasBounds && GPMPVGetSecondaryASS(other).hasBounds);
    GPMPVClearSecondaryASS(other);
    CHECK(states == NULL);
    printf("%d native ASS geometry checks passed\n", checks);
}

#import "GenPlayerMPVBridge.h"
#include "NativeASSGeometry.h"
#include <pthread.h>
#include <math.h>

struct mpv_handle;
extern struct mpv_global *mp_client_get_global(struct mpv_handle *handle);
extern const char *GPMPVASSRendererRevision(void);

typedef struct GPASSState {
    struct mpv_global *global;
    int64_t track;
    double scale, centerY, anchorY;
    BOOL hasAnchor, dirty, mirror;
    GPMPVSecondaryASSGeometry geometry;
    CGRect originalBounds;
    const void *decoder;
    struct GPASSState *next;
} GPASSState;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static GPASSState *states;

static GPASSState *findState(struct mpv_global *global) {
    for (GPASSState *s = states; s; s = s->next)
        if (s->global == global) return s;
    return NULL;
}

static CGRect transformedBounds(GPASSState *s) {
    CGRect b = s->originalBounds;
    double offset = s->centerY >= 0 ? s->centerY - s->anchorY : 0;
    return CGRectMake(0.5 + (b.origin.x - 0.5) * s->scale,
                      s->anchorY + (b.origin.y - s->anchorY) * s->scale + offset,
                      b.size.width * s->scale, b.size.height * s->scale);
}

void GPMPVSetSecondaryASS(void *handle, int64_t track, double scale, double centerY) {
    if (!handle) return;
    (void)GPMPVASSRendererRevision(); // Pull in the pinned sd_ass replacement before libmpv.
    struct mpv_global *global = mp_client_get_global(handle);
    pthread_mutex_lock(&lock);
    GPASSState *s = findState(global);
    if (!s && track >= 0) {
        s = calloc(1, sizeof(*s));
        if (!s) { pthread_mutex_unlock(&lock); return; }
        s->global = global; s->track = -1; s->next = states; states = s;
    }
    if (s) {
        scale = isfinite(scale) ? fmin(2.0, fmax(0.5, scale)) : 1;
        centerY = isfinite(centerY) && centerY >= 0 ? fmin(0.92, fmax(0.08, centerY)) : -1;
        if (track != s->track) { s->geometry = (GPMPVSecondaryASSGeometry){0}; s->hasAnchor = NO; s->decoder = NULL; }
        s->dirty |= track != s->track || scale != s->scale || centerY != s->centerY;
        // The first drag starts from the current cue, not an earlier cue's height.
        if (s->geometry.hasBounds && s->centerY < 0 && centerY >= 0)
            s->anchorY = CGRectGetMidY(s->originalBounds);
        s->track = track; s->scale = scale; s->centerY = centerY;
        if (s->geometry.hasBounds) s->geometry.bounds = transformedBounds(s);
    }
    pthread_mutex_unlock(&lock);
}

void GPMPVSetSecondaryASSMirror(void *handle, bool enabled) {
    if (!handle) return;
    struct mpv_global *global = mp_client_get_global(handle);
    pthread_mutex_lock(&lock);
    GPASSState *s = findState(global);
    if (!s) {
        s = calloc(1, sizeof(*s));
        if (s) { s->global = global; s->track = -1; s->next = states; states = s; }
    }
    if (s && s->mirror != enabled) {
        s->mirror = enabled; s->dirty = YES;
        s->geometry = (GPMPVSecondaryASSGeometry){0}; s->hasAnchor = NO; s->decoder = NULL;
    }
    pthread_mutex_unlock(&lock);
}

bool GPMPVMirrorsPrimaryASS(struct mpv_global *global) {
    pthread_mutex_lock(&lock);
    GPASSState *s = findState(global);
    bool enabled = s && s->track >= 0 && s->mirror;
    pthread_mutex_unlock(&lock);
    return enabled;
}

GPMPVSecondaryASSGeometry GPMPVGetSecondaryASS(void *handle) {
    GPMPVSecondaryASSGeometry result = {0};
    if (!handle) return result;
    struct mpv_global *global = mp_client_get_global(handle);
    pthread_mutex_lock(&lock);
    GPASSState *s = findState(global);
    if (s && s->track >= 0) result = s->geometry;
    pthread_mutex_unlock(&lock);
    return result;
}

void GPMPVClearSecondaryASS(void *handle) {
    if (!handle) return;
    struct mpv_global *global = mp_client_get_global(handle);
    pthread_mutex_lock(&lock);
    GPASSState **p = &states;
    while (*p) {
        if ((*p)->global == global) { GPASSState *old = *p; *p = old->next; free(old); break; }
        p = &(*p)->next;
    }
    pthread_mutex_unlock(&lock);
}

bool GPMPVHasSecondaryASS(struct mpv_global *global, int order) {
    if (order != 1) return false;
    pthread_mutex_lock(&lock);
    GPASSState *s = findState(global);
    bool enabled = s && s->track >= 0;
    pthread_mutex_unlock(&lock);
    return enabled;
}

// Called on mpv's render thread after sub_bitmaps_copy. Only the private copy's
// destination rectangles change: glyph pixels, ASS timing and clip masks remain
// intact. No file/network work, screenshots, or video pixel reads occur here.
void GPMPVTransformSecondaryASS(struct mpv_global *global, int order, const void *decoder,
                               struct mp_osd_res dim, struct sub_bitmaps *parts) {
    if (order != 1 || dim.w <= 0 || dim.h <= 0) return;
    pthread_mutex_lock(&lock);
    GPASSState *s = findState(global);
    if (!s || s->track < 0) { pthread_mutex_unlock(&lock); return; }
    if (s->decoder != decoder) {
        s->decoder = decoder;
        s->geometry = (GPMPVSecondaryASSGeometry){0};
        s->hasAnchor = NO;
        s->dirty = YES;
    }
    // A selection/configuration can change after the pack-format check. Never
    // move an A8/LIBASS frame: its software blender assumes clipped 1:1 pixels.
    if (parts && parts->num_parts > 0 && parts->format != SUBBITMAP_BGRA) {
        pthread_mutex_unlock(&lock);
        return;
    }
    s->geometry.hasContent = parts && parts->num_parts > 0;
    if (!s->geometry.hasContent) { pthread_mutex_unlock(&lock); return; }
    CGRect original = CGRectNull;
    for (int i = 0; i < parts->num_parts; i++) {
        struct sub_bitmap *p = &parts->parts[i];
        if (p->dw > 0 && p->dh > 0)
            original = CGRectUnion(original, CGRectMake(p->x, p->y, p->dw, p->dh));
    }
    if (CGRectIsNull(original)) { s->geometry.hasContent = NO; pthread_mutex_unlock(&lock); return; }
    s->originalBounds = CGRectMake(original.origin.x / dim.w, original.origin.y / dim.h,
                                  original.size.width / dim.w, original.size.height / dim.h);
    if (!s->hasAnchor) { s->anchorY = CGRectGetMidY(original) / dim.h; s->hasAnchor = YES; }
    const double ax = dim.w * 0.5, ay = dim.h * s->anchorY;
    const double offset = s->centerY >= 0 ? (s->centerY - s->anchorY) * dim.h : 0;
    CGRect bounds = CGRectNull;
    for (int i = 0; i < parts->num_parts; i++) {
        struct sub_bitmap *p = &parts->parts[i];
        p->x = (int)lrint(ax + (p->x - ax) * s->scale);
        p->y = (int)lrint(ay + (p->y - ay) * s->scale + offset);
        p->dw = MAX(1, (int)lrint(p->dw * s->scale));
        p->dh = MAX(1, (int)lrint(p->dh * s->scale));
        bounds = CGRectUnion(bounds, CGRectMake(p->x, p->y, p->dw, p->dh));
    }
    // Cache invalidation is required even when the paused ASS cue is unchanged.
    if (s->dirty) { parts->change_id++; s->dirty = NO; }
    s->geometry.bounds = CGRectMake(bounds.origin.x / dim.w, bounds.origin.y / dim.h,
                                   bounds.size.width / dim.w, bounds.size.height / dim.h);
    s->geometry.hasBounds = YES;
    pthread_mutex_unlock(&lock);
}

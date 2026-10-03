// Synthetic ASS renderer test. No player, window, media file, network or capture.
#include "sub/osd.h"
#include "video/mp_image.h"
static struct sub_bitmaps *tracked_copy(struct sub_bitmap_copy_cache **cache, struct sub_bitmaps *in);
static struct mp_image *fixture_image_alloc(int format, int w, int h);
#define sub_bitmaps_copy tracked_copy
#define mp_image_alloc fixture_image_alloc
#import "../../GenPlayerCore/Sources/GenPlayerMPVBridge/NativeASSRenderer.m"
#undef sub_bitmaps_copy
#undef mp_image_alloc
static int live_copies;
static bool fail_atlas;
static void copy_destroyed(void *ptr) { live_copies--; }
static struct sub_bitmaps *tracked_copy(struct sub_bitmap_copy_cache **cache, struct sub_bitmaps *in) {
    struct sub_bitmaps *result = sub_bitmaps_copy(cache, in);
    if (result) { live_copies++; talloc_set_destructor(result, copy_destroyed); }
    return result;
}
static struct mp_image *fixture_image_alloc(int format, int w, int h) {
    return fail_atlas ? NULL : mp_image_alloc(format, w, h);
}
#define mp_client_get_global fixture_global
#import "../../GenPlayerCore/Sources/GenPlayerMPVBridge/NativeASSGeometry.m"
#undef mp_client_get_global
#include <assert.h>
struct mpv_global *fixture_global(struct mpv_handle *handle) { return (void *)handle; }
static int checks;
#define CHECK(x) do { assert(x); checks++; } while (0)
static struct sub_bitmaps *checked_frame(struct sd *sd, struct mp_osd_res dim, int format, double pts) {
    int before = live_copies;
    struct sub_bitmaps *result = get_bitmaps(sd, dim, format, pts);
    CHECK(live_copies == before + (result != NULL));
    return result;
}
static uint64_t pixels(struct sub_bitmaps *b) {
    uint64_t hash = 1469598103934665603ULL;
    for (int i=0; i<b->num_parts; i++) {
        struct sub_bitmap *p=&b->parts[i];
        for (int y=0; y<p->h; y++) for (int x=0; x<p->w*4; x++)
            hash = (hash ^ ((uint8_t *)p->bitmap)[y*p->stride+x]) * 1099511628211ULL;
    }
    return hash;
}
int main(void) {
    struct sd sd = {0};
    struct sd_ass_priv *ctx = talloc_zero(NULL, struct sd_ass_priv);
    struct osd_style_opts style = {.font="Arial", .font_size=32};
    struct mp_subtitle_opts opts = {.ass_enabled=true, .sub_style=&style, .sub_scale=1, .sub_speed=1, .ass_prune_delay=-1};
    struct mp_subtitle_shared_opts shared = {.sub_visibility={true,true}, .sub_pos={100,100}};
    sd.priv=ctx; sd.opts=&opts; sd.shared_opts=&shared; sd.global=(void *)&sd;
    ctx->ass_library=ass_library_init();
    ctx->ass_renderer=ass_renderer_init(ctx->ass_library);
    ctx->mirror_renderer=ass_renderer_init(ctx->ass_library);
    ass_set_fonts(ctx->ass_renderer,NULL,"Arial",1,NULL,1);
    ass_set_fonts(ctx->mirror_renderer,NULL,"Arial",1,NULL,1);
    char script[] = "[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n"
        "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,32,&H000000FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\\pos(100,100)\\p1}m 0 0 l 60 0 60 20 0 20\n"
        "Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\\move(200,100,260,100)\\c&H00FF00&\\p1}m 0 0 l 30 0 30 20 0 20\n";
    ctx->ass_track=ass_read_memory(ctx->ass_library,script,strlen(script),NULL);
    ctx->shadow_track=ass_new_track(ctx->ass_library);
    ctx->packer=mp_ass_packer_alloc(ctx);
    ctx->video_params=(struct mp_image_params){.w=640,.h=360,.p_w=1,.p_h=1};
    struct mp_osd_res dim={.w=640,.h=360,.display_par=1};
    struct sub_bitmaps *base=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(base && base->num_parts>0);
    int primaryCount=base->num_parts, primaryWidth=base->parts[0].dw, primaryX=base->parts[0].x;
    uint64_t primaryPixels=pixels(base);
    talloc_free(base); base=NULL;
    GPMPVSetSecondaryASS(&sd,1,1,0.75);
    GPMPVSetSecondaryASSMirror(&sd,true);
    struct sub_bitmaps *both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(both && both->num_parts==primaryCount*2 && both->change_id>0);
    CHECK(GPMPVGetSecondaryASS(&sd).hasContent);
    struct sub_bitmaps first=*both; first.num_parts=primaryCount;
    struct sub_bitmaps second=*both; second.parts+=primaryCount; second.num_parts=primaryCount;
    CHECK(pixels(&first)==primaryPixels && pixels(&second)==primaryPixels);
    CHECK(second.parts[0].y>first.parts[0].y);
    int stable=both->change_id;
    // Geometry's first dirty notification may settle on the next frame.
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    stable=both->change_id;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(both->change_id==stable);
    shared.sub_delay[1]=-2;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    first=*both; first.num_parts=primaryCount;
    second=*both; second.parts+=primaryCount; second.num_parts=both->num_parts-primaryCount;
    CHECK(pixels(&first)==primaryPixels && pixels(&second)!=primaryPixels);
    int animatedX=both->parts[primaryCount].x;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1.5);
    CHECK(both->parts[primaryCount].x>animatedX && both->parts[0].x==primaryX);
    shared.sub_delay[0]=1; shared.sub_delay[1]=-1;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(both->parts[primaryCount].x==animatedX); // Both delay values contribute.
    shared.sub_delay[0]=0; shared.sub_delay[1]=-2;
    GPMPVSetSecondaryASS(&sd,1,1.5,0.5);
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(both->parts[0].dw==primaryWidth);
    CHECK(both->parts[primaryCount].dw>both->parts[primaryCount].w);
    shared.sub_delay[1]=-8;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(both->num_parts==primaryCount && !GPMPVGetSecondaryASS(&sd).hasContent);
    shared.sub_delay[1]=0;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    // Primary in a gap, delayed second slot still has its authored cue.
    shared.sub_delay[1]=4;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,5);
    CHECK(both->num_parts==primaryCount && GPMPVGetSecondaryASS(&sd).hasContent);
    // Both slots in a gap, then paused seek back into the same-track cue.
    shared.sub_delay[1]=0;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,5);
    CHECK((!both || both->num_parts==0) && !GPMPVGetSecondaryASS(&sd).hasContent);
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(both->num_parts==primaryCount*2 && both->change_id>0);
    // Repeated unchanged frames must release both temporary copies as well.
    for (int i=0; i<1000; i++) {
        talloc_free(both);
        both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    }
    // Force atlas allocation failure: return the still-live primary copy.
    ctx->combined_valid=false;
    fail_atlas=true;
    talloc_free(both);
    both=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(both && both->num_parts==primaryCount && pixels(both)==primaryPixels);
    fail_atlas=false;
    talloc_free(both); both=NULL;
    GPMPVSetSecondaryASSMirror(&sd,false);
    base=checked_frame(&sd,dim,SUBBITMAP_BGRA,1);
    CHECK(base->num_parts==primaryCount && base->change_id>0 && pixels(base)==primaryPixels);
    talloc_free(base);
    CHECK(live_copies==0);
    GPMPVClearSecondaryASS(&sd);
    uninit(&sd); talloc_free(ctx);
    printf("%d native ASS mirror pixel/timing/lifecycle checks passed\n",checks);
}

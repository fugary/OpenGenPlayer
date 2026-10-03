// Exercise the actual context event handler with a fake swapchain; no window,
// media, Vulkan device or GenPlayer process is created.
#import "../../GenPlayerCore/Sources/GenPlayerMPVBridge/MetalContext.m"

static int wakeups, resizes;
static bool resizeSucceeds = true;
void vo_wakeup(struct vo *vo) { assert(vo); wakeups++; }
bool ra_vk_ctx_resize(struct ra_ctx *ctx, int width, int height) {
    resizes++;
    if (!resizeSucceeds) return false;
    ctx->vo->dwidth = width;
    ctx->vo->dheight = height;
    return true;
}
void ra_vk_ctx_uninit(struct ra_ctx *ctx) {}
void mpvk_uninit(struct mpvk_ctx *vk) {}
bool mpvk_init(struct mpvk_ctx *vk, struct ra_ctx *ctx, const char *ext) { return false; }
bool ra_vk_ctx_init(struct ra_ctx *ctx, struct mpvk_ctx *vk, struct ra_ctx_params params, VkPresentModeKHR mode) { return false; }
VkResult vkCreateMetalSurfaceEXT(VkInstance instance, const VkMetalSurfaceCreateInfoEXT *info, const VkAllocationCallbacks *alloc, VkSurfaceKHR *surface) { return VK_ERROR_INITIALIZATION_FAILED; }
#undef ta_zalloc_size
void *ta_dbg_set_loc(void *ptr, const char *name) { return ptr; }
void *ta_zalloc_size(void *parent, size_t size) { return calloc(1, size); }
void mp_msg(struct mp_log *log, int level, const char *format, ...) {}

static void checkSize(struct ra_ctx *ctx, GPMPVMetalLayer *layer, int w, int h) {
    int oldResizes = resizes, oldWakeups = wakeups, events = VO_EVENT_WIN_STATE;
    layer.targetPixelSize = CGSizeMake(w, h);
    assert(wakeups == oldWakeups + 1);
    assert(ra_ctx_vulkan_moltenvk.control(ctx, &events, VOCTRL_CHECK_EVENTS, NULL) == VO_TRUE);
    assert(resizes == oldResizes + 1);
    assert(ctx->vo->dwidth == w && ctx->vo->dheight == h);
    assert((events & (VO_EVENT_RESIZE | VO_EVENT_EXPOSE | VO_EVENT_WIN_STATE)) ==
           (VO_EVENT_RESIZE | VO_EVENT_EXPOSE | VO_EVENT_WIN_STATE));
}
int main(void) { @autoreleasepool {
    GPMPVMetalLayer *layer = [GPMPVMetalLayer new];
    struct vo vo = {0};
    struct priv state = {.layer = layer};
    struct ra_ctx ctx = {.vo = &vo, .priv = &state};
    [layer bindVideoOutput:&vo];
    checkSize(&ctx, layer, 1071, 602); // initial layout
    checkSize(&ctx, layer, 2142, 1204); // Retina scale doubles
    checkSize(&ctx, layer, 2142, 1156); // shrink from the reported assertion
    checkSize(&ctx, layer, 3840, 2160); // fullscreen
    int oldResizes = resizes, oldWakeups = wakeups, events = 0;
    layer.targetPixelSize = layer.targetPixelSize;
    layer.targetPixelSize = CGSizeZero;
    layer.targetPixelSize = CGSizeMake(NAN, 100);
    layer.targetPixelSize = CGSizeMake(INFINITY, 100);
    layer.targetPixelSize = CGSizeMake((double)INT_MAX + 1, 100);
    assert(ra_ctx_vulkan_moltenvk.control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL) == VO_TRUE);
    assert(events == 0 && resizes == oldResizes && wakeups == oldWakeups);
    // A paused VO is woken without needing a video frame; successive layouts coalesce.
    layer.targetPixelSize = CGSizeMake(800, 600);
    layer.targetPixelSize = CGSizeMake(1600, 900);
    resizeSucceeds = false;
    assert(ra_ctx_vulkan_moltenvk.control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL) == VO_ERROR);
    assert(events == 0 && vo.dwidth == 3840);
    resizeSucceeds = true;
    assert(ra_ctx_vulkan_moltenvk.control(&ctx, &events, VOCTRL_CHECK_EVENTS, NULL) == VO_TRUE);
    assert(vo.dwidth == 1600 && vo.dheight == 900 && events & VO_EVENT_RESIZE);
    assert(resizes == oldResizes + 2);
    assert(ra_ctx_vulkan_moltenvk.control(&ctx, &events, VOCTRL_RESET, NULL) == VO_NOTIMPL);
    ra_ctx_vulkan_moltenvk.uninit(&ctx);
    oldWakeups = wakeups;
    layer.targetPixelSize = CGSizeMake(900, 600);
    assert(wakeups == oldWakeups); // no stale VO pointer after teardown
    puts("PASS: initial/Retina/shrink/fullscreen geometry, wakeup, coalescing, retry, invalid geometry and teardown (fake GPU)");
} }

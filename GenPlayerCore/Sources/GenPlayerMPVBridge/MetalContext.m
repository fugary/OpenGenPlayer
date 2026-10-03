/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/CAMetalLayer.h>
#import "GenPlayerMPVBridge.h"
#import <Foundation/Foundation.h>
#include <math.h>

#include "video/out/vulkan/common.h"
#include "video/out/vulkan/context.h"
#include "video/out/vulkan/utils.h"

// Offsets verified against MPVKit 1.0.0's arm64 context objects. Fail the build
// if compiler configuration changes the private ABI used by this adapter.
#if defined(__aarch64__)
_Static_assert(offsetof(struct ra_ctx, priv) == 0x50, "mpv ra_ctx ABI changed");
_Static_assert(offsetof(struct ra_ctx, log) == 0x18, "mpv log ABI changed");
_Static_assert(offsetof(struct vo, opts) == 0xe0, "mpv vo ABI changed");
_Static_assert(offsetof(struct vo, dwidth) == 0xf8, "mpv viewport ABI changed");
_Static_assert(offsetof(struct mp_vo_opts, WinID) == 0x120, "mpv wid ABI changed");
_Static_assert(sizeof(struct mpvk_ctx) == 0x30, "mpv Vulkan ABI changed");
#endif

// Compiled with the pinned mpv 0.41.0 headers. The archive's original context
// object is not extracted because this target supplies the same context symbol.
@interface GPMPVMetalLayer () {
    NSLock *_sizeLock;
    CGSize _targetPixelSize;
    struct vo *_videoOutput;
}
- (void)bindVideoOutput:(struct vo *)vo;
@end

@implementation GPMPVMetalLayer
- (instancetype)init {
    self = [super init];
    if (self) _sizeLock = [NSLock new];
    return self;
}
- (CGSize)targetPixelSize {
    [_sizeLock lock];
    CGSize size = _targetPixelSize;
    [_sizeLock unlock];
    return size;
}
- (void)setTargetPixelSize:(CGSize)size {
    if (!isfinite(size.width) || !isfinite(size.height) ||
        size.width < 2 || size.height < 2 || size.width > INT_MAX || size.height > INT_MAX)
        return;
    size = CGSizeMake(round(size.width), round(size.height));
    [_sizeLock lock];
    if (!CGSizeEqualToSize(_targetPixelSize, size)) {
        _targetPixelSize = size;
        // uninit clears this pointer under the same lock before VO destruction.
        // vo_wakeup is the one VO operation explicitly safe from other threads.
        if (_videoOutput) vo_wakeup(_videoOutput);
    }
    [_sizeLock unlock];
}
- (void)bindVideoOutput:(struct vo *)vo {
    [_sizeLock lock];
    _videoOutput = vo;
    [_sizeLock unlock];
}
@end

struct priv {
    struct mpvk_ctx vk;
    __unsafe_unretained GPMPVMetalLayer *layer;
    CGSize appliedSize;
};

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    [p->layer bindVideoOutput:NULL];
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    {
        GPMPVMetalLayer *layer = (__bridge GPMPVMetalLayer *)(void *)(intptr_t)ctx->vo->opts->WinID;
        if (![layer isKindOfClass:[GPMPVMetalLayer class]])
            goto fail;
        p->layer = layer; // The Swift engine retains the layer through mpv destruction.
        [layer bindVideoOutput:ctx->vo];
        VkMetalSurfaceCreateInfoEXT info = {
            .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
            .pLayer = layer,
        };
        struct ra_ctx_params params = {0};
        VkResult res = vkCreateMetalSurfaceEXT(vk->vkinst->instance, &info, NULL, &vk->surface);
        if (res != VK_SUCCESS) {
            MP_MSG(ctx, msgl, "Failed creating MoltenVK surface\n");
            goto fail;
        }
        if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
            goto fail;
    }

    return true;
fail:
    moltenvk_uninit(ctx);
    return false;
}

static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    CGSize size = p->layer.targetPixelSize;
    if (size.width < 2 || size.height < 2)
        return false;
    // This runs between frames on the VO thread. The helper recreates the
    // swapchain AND updates vo->dwidth/dheight used for video/OSD placement.
    if (!ra_vk_ctx_resize(ctx, (int)size.width, (int)size.height))
        return false;
    p->appliedSize = size;
    return true;
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    if (request == VOCTRL_CHECK_EVENTS) {
        struct priv *p = ctx->priv;
        if (!CGSizeEqualToSize(p->appliedSize, p->layer.targetPixelSize)) {
            if (!moltenvk_reconfig(ctx))
                return VO_ERROR;
            *events |= VO_EVENT_RESIZE | VO_EVENT_EXPOSE;
        }
        return VO_TRUE;
    }
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .description    = "GenPlayer Metal resize context (mpv 0.41.0)",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};

const char *GPMPVMetalContextRevision(void) {
    return ra_ctx_vulkan_moltenvk.description;
}

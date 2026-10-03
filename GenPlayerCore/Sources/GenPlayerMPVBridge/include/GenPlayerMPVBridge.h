#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN
/// Pins the link-time replacement for MPVKit 1.0.0's moltenvk context.
FOUNDATION_EXPORT const char *GPMPVMetalContextRevision(void);

typedef struct {
    CGRect bounds; // Normalized to the OSD viewport, including letterbox margins.
    bool hasBounds;
    bool hasContent;
} GPMPVSecondaryASSGeometry;
/// Scoped to one libmpv instance; no primary subtitle or tvOS override.
FOUNDATION_EXPORT void GPMPVSetSecondaryASS(void *handle, int64_t track,
                                           double scale, double centerY);
FOUNDATION_EXPORT void GPMPVSetSecondaryASSMirror(void *handle, bool enabled);
FOUNDATION_EXPORT GPMPVSecondaryASSGeometry GPMPVGetSecondaryASS(void *handle);
FOUNDATION_EXPORT void GPMPVClearSecondaryASS(void *handle);

/// Geometry requests cross to mpv's VO thread; callers never resize live drawables.
@interface GPMPVMetalLayer : CAMetalLayer
@property(nonatomic) CGSize targetPixelSize;
@end
NS_ASSUME_NONNULL_END

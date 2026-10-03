#import "GenPlayerVLCFrameBridge.h"

#import <QuartzCore/CAMediaTiming.h>
#import <stdatomic.h>

typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);
typedef unsigned (*libvlc_video_format_cb)(void **opaque, char *chroma,
                                           unsigned *width, unsigned *height,
                                           unsigned *pitches, unsigned *lines);
typedef void (*libvlc_video_cleanup_cb)(void *opaque);

extern void libvlc_video_set_callbacks(libvlc_media_player_t *mp,
                                       libvlc_video_lock_cb lock,
                                       libvlc_video_unlock_cb unlock,
                                       libvlc_video_display_cb display,
                                       void *opaque);
extern void libvlc_video_set_format_callbacks(libvlc_media_player_t *mp,
                                              libvlc_video_format_cb setup,
                                              libvlc_video_cleanup_cb cleanup);

@interface VLCMediaPlayer (GenPlayerPrivatePlayerInstance)
@property (readonly) libvlc_media_player_t *playerInstance;
@end

static NSInteger GenPlayerAlignUpInteger(NSInteger value, NSInteger alignment)
{
    if (alignment <= 1) {
        return value;
    }
    NSInteger remainder = value % alignment;
    if (remainder == 0) {
        return value;
    }
    return value + alignment - remainder;
}

@interface GenPlayerVLCFrameBuffer : NSObject
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) void *baseAddress;
@end

@implementation GenPlayerVLCFrameBuffer

- (void)dealloc
{
    if (_pixelBuffer != NULL) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

@end

@interface GenPlayerVLCFrameCallbackState : NSObject
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) unsigned frameWidth;
@property (nonatomic, assign) unsigned frameHeight;
@property (nonatomic, assign) unsigned framePitch;
@property (nonatomic, assign) BOOL attached;
@property (nonatomic, assign) CFTimeInterval lastDeliveredFrameTime;
@end

@implementation GenPlayerVLCFrameCallbackState

- (void)dealloc
{
    if (_pixelBufferPool != NULL) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
}

@end

@interface GenPlayerVLCFrameCallbackContext : NSObject
@property (nonatomic, weak) GenPlayerVLCFrameBridge *bridge;
@property (nonatomic, strong) GenPlayerVLCFrameCallbackState *state;
@end

@implementation GenPlayerVLCFrameCallbackContext
@end

static NSMutableArray<GenPlayerVLCFrameCallbackContext *> *GenPlayerDetachedFrameCallbackContexts(void)
{
    static NSMutableArray<GenPlayerVLCFrameCallbackContext *> *contexts = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        contexts = [NSMutableArray array];
    });
    return contexts;
}

static NSTimeInterval GenPlayerDetachedFrameCallbackContextGracePeriod(void)
{
    return 60.0;
}

static void GenPlayerRetainDetachedFrameCallbackContext(GenPlayerVLCFrameCallbackContext *context)
{
    if (context == nil) {
        return;
    }
    NSMutableArray<GenPlayerVLCFrameCallbackContext *> *contexts = GenPlayerDetachedFrameCallbackContexts();
    @synchronized (contexts) {
        [contexts addObject:context];
    }
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(GenPlayerDetachedFrameCallbackContextGracePeriod() * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            NSMutableArray<GenPlayerVLCFrameCallbackContext *> *retainedContexts =
                GenPlayerDetachedFrameCallbackContexts();
            @synchronized (retainedContexts) {
                [retainedContexts removeObjectIdenticalTo:context];
            }
        }
    );
}

@interface GenPlayerVLCFrameBridge ()
@property (nonatomic, weak) VLCMediaPlayer *mediaPlayer;
@property (nonatomic, assign) libvlc_media_player_t *playerInstance;
@property (nonatomic, assign, getter=isAttached) BOOL attached;
@property (nonatomic, assign) CGSize currentVideoSize;
@property (nonatomic, strong) GenPlayerVLCFrameCallbackContext *callbackContext;
@property (nonatomic, strong) GenPlayerVLCFrameCallbackState *callbackState;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) unsigned frameWidth;
@property (nonatomic, assign) unsigned frameHeight;
@property (nonatomic, assign) unsigned framePitch;
@property (nonatomic, assign) CFTimeInterval lastDeliveredFrameTime;
@property (nonatomic, assign) _Atomic(int) inFlightFrameCount;

- (void *)lockedFrameBufferWithPlanes:(void **)planes;
- (void)unlockFrameBuffer:(void *)picture planes:(void *const *)planes;
- (void)displayFrameBuffer:(void *)picture;
- (unsigned)configureWithChroma:(char *)chroma
                          width:(unsigned *)width
                         height:(unsigned *)height
                        pitches:(unsigned *)pitches
                          lines:(unsigned *)lines;
- (void)cleanupConfiguredFormat;
@end

static void *GenPlayerVLCFrameLock(void *opaque, void **planes)
{
    if (opaque == NULL) {
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    id object = (__bridge id)opaque;
    if (![object isKindOfClass:[GenPlayerVLCFrameCallbackContext class]]) {
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    GenPlayerVLCFrameCallbackContext *context = (GenPlayerVLCFrameCallbackContext *)object;
    GenPlayerVLCFrameCallbackState *state = context.state;
    if (state == nil) {
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    unsigned width = 0;
    unsigned height = 0;
    unsigned pitch = 0;
    CVPixelBufferPoolRef pixelBufferPool = NULL;
    BOOL attached = NO;
    @synchronized (state) {
        width = state.frameWidth;
        height = state.frameHeight;
        pitch = state.framePitch;
        attached = state.attached;
        pixelBufferPool = state.pixelBufferPool;
        if (pixelBufferPool != NULL) {
            CVPixelBufferPoolRetain(pixelBufferPool);
        }
    }

    if (!attached || width == 0 || height == 0 || pitch == 0 || pixelBufferPool == NULL) {
        if (pixelBufferPool != NULL) {
            CVPixelBufferPoolRelease(pixelBufferPool);
        }
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer);
    CVPixelBufferPoolRelease(pixelBufferPool);
    if (status != kCVReturnSuccess || pixelBuffer == NULL) {
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (baseAddress == NULL || bytesPerRow < pitch) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    GenPlayerVLCFrameBuffer *frameBuffer = [GenPlayerVLCFrameBuffer new];
    frameBuffer.pixelBuffer = pixelBuffer;
    frameBuffer.baseAddress = baseAddress;

    if (planes != NULL) {
        planes[0] = baseAddress;
    }
    return (__bridge_retained void *)frameBuffer;
}

static void GenPlayerVLCFrameUnlock(void *opaque, void *picture, void *const *planes)
{
    (void)opaque;
    GenPlayerVLCFrameBuffer *frameBuffer = (__bridge GenPlayerVLCFrameBuffer *)picture;
    if ([frameBuffer isKindOfClass:[GenPlayerVLCFrameBuffer class]] && frameBuffer.pixelBuffer != NULL && frameBuffer.baseAddress != NULL) {
        CVPixelBufferUnlockBaseAddress(frameBuffer.pixelBuffer, 0);
        frameBuffer.baseAddress = NULL;
    }
    (void)planes;
}

static void GenPlayerVLCFrameDisplay(void *opaque, void *picture)
{
    if (opaque == NULL) {
        if (picture != NULL) {
            CFBridgingRelease(picture);
        }
        return;
    }

    id object = (__bridge id)opaque;
    if (![object isKindOfClass:[GenPlayerVLCFrameCallbackContext class]]) {
        if (picture != NULL) {
            CFBridgingRelease(picture);
        }
        return;
    }

    GenPlayerVLCFrameCallbackContext *context = (GenPlayerVLCFrameCallbackContext *)object;
    GenPlayerVLCFrameBridge *bridge = context.bridge;
    if (bridge == nil) {
        if (picture != NULL) {
            CFBridgingRelease(picture);
        }
        return;
    }
    [bridge displayFrameBuffer:picture];
}

static unsigned GenPlayerVLCFrameSetup(void **opaque, char *chroma,
                                       unsigned *width, unsigned *height,
                                       unsigned *pitches, unsigned *lines)
{
    if (opaque == NULL || *opaque == NULL) {
        return 0;
    }

    id object = (__bridge id)*opaque;
    if (![object isKindOfClass:[GenPlayerVLCFrameCallbackContext class]]) {
        return 0;
    }

    GenPlayerVLCFrameCallbackContext *context = (GenPlayerVLCFrameCallbackContext *)object;
    GenPlayerVLCFrameBridge *bridge = context.bridge;
    if (bridge == nil) {
        return 0;
    }
    return [bridge configureWithChroma:chroma
                                 width:width
                                height:height
                               pitches:pitches
                                 lines:lines];
}

static void GenPlayerVLCFrameCleanup(void *opaque)
{
    if (opaque == NULL) {
        return;
    }

    id object = (__bridge id)opaque;
    if ([object isKindOfClass:[GenPlayerVLCFrameCallbackContext class]]) {
        GenPlayerVLCFrameCallbackContext *context = (GenPlayerVLCFrameCallbackContext *)object;
        GenPlayerVLCFrameBridge *bridge = context.bridge;
        if (bridge != nil) {
            [bridge cleanupConfiguredFormat];
        }
    }
}

@implementation GenPlayerVLCFrameBridge

- (instancetype)init
{
    self = [super init];
    if (self) {
        _maximumRenderWidth = 480;
        _minimumFrameInterval = 1.0 / 30.0;
        _currentVideoSize = CGSizeZero;
    }
    return self;
}

- (void)dealloc
{
    [self detach];
}

- (BOOL)attachToMediaPlayer:(VLCMediaPlayer *)mediaPlayer error:(NSError * _Nullable __autoreleasing *)error
{
    [self detach];

    libvlc_media_player_t *playerInstance = mediaPlayer.playerInstance;
    if (playerInstance == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"GenPlayerVLCFrameBridge"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing libVLC player instance"}];
        }
        return NO;
    }

    @synchronized (self) {
        self.mediaPlayer = mediaPlayer;
        self.playerInstance = playerInstance;
        self.attached = YES;
        self.callbackContext = [GenPlayerVLCFrameCallbackContext new];
        self.callbackContext.bridge = self;
        self.callbackState = [GenPlayerVLCFrameCallbackState new];
        self.callbackState.attached = YES;
        self.callbackContext.state = self.callbackState;
        self.currentVideoSize = CGSizeZero;
        self.frameWidth = 0;
        self.frameHeight = 0;
        self.framePitch = 0;
        self.lastDeliveredFrameTime = 0;
    }

    libvlc_video_set_callbacks(playerInstance,
                               GenPlayerVLCFrameLock,
                               GenPlayerVLCFrameUnlock,
                               GenPlayerVLCFrameDisplay,
                               (__bridge void *)self.callbackContext);
    libvlc_video_set_format_callbacks(playerInstance,
                                      GenPlayerVLCFrameSetup,
                                      GenPlayerVLCFrameCleanup);
    return YES;
}

- (void)detach
{
    libvlc_media_player_t *playerInstance = NULL;
    GenPlayerVLCFrameCallbackContext *callbackContext = nil;
    @synchronized (self) {
        playerInstance = self.playerInstance;
        callbackContext = self.callbackContext;
        self.playerInstance = NULL;
        self.mediaPlayer = nil;
        self.attached = NO;
        self.callbackContext = nil;
        self.callbackState = nil;
        self.currentVideoSize = CGSizeZero;
        self.frameWidth = 0;
        self.frameHeight = 0;
        self.framePitch = 0;
        self.lastDeliveredFrameTime = 0;
        if (self.pixelBufferPool != NULL) {
            CVPixelBufferPoolRelease(self.pixelBufferPool);
            self.pixelBufferPool = NULL;
        }
    }

    callbackContext.bridge = nil;

    if (playerInstance != NULL) {
        libvlc_video_set_format_callbacks(playerInstance, NULL, NULL);
        libvlc_video_set_callbacks(playerInstance, NULL, NULL, NULL, NULL);
    }
    GenPlayerRetainDetachedFrameCallbackContext(callbackContext);
}

- (void *)lockedFrameBufferWithPlanes:(void **)planes
{
    unsigned width = 0;
    unsigned height = 0;
    unsigned pitch = 0;
    BOOL attached = NO;
    CVPixelBufferPoolRef pixelBufferPool = NULL;

    @synchronized (self) {
        attached = self.attached;
        width = self.frameWidth;
        height = self.frameHeight;
        pitch = self.framePitch;
        pixelBufferPool = self.pixelBufferPool;
        if (pixelBufferPool != NULL) {
            CVPixelBufferPoolRetain(pixelBufferPool);
        }
    }

    if (!attached || width == 0 || height == 0 || pitch == 0 || pixelBufferPool == NULL) {
        if (pixelBufferPool != NULL) {
            CVPixelBufferPoolRelease(pixelBufferPool);
        }
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer);
    CVPixelBufferPoolRelease(pixelBufferPool);
    if (status != kCVReturnSuccess || pixelBuffer == NULL) {
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (baseAddress == NULL || bytesPerRow < pitch) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        if (planes != NULL) {
            planes[0] = NULL;
        }
        return NULL;
    }

    GenPlayerVLCFrameBuffer *frameBuffer = [GenPlayerVLCFrameBuffer new];
    frameBuffer.pixelBuffer = pixelBuffer;
    frameBuffer.baseAddress = baseAddress;

    if (planes != NULL) {
        planes[0] = baseAddress;
    }

    return (__bridge_retained void *)frameBuffer;
}

- (void)unlockFrameBuffer:(void *)picture planes:(void *const *)planes
{
    GenPlayerVLCFrameBuffer *frameBuffer = (__bridge GenPlayerVLCFrameBuffer *)picture;
    if (frameBuffer.pixelBuffer != NULL && frameBuffer.baseAddress != NULL) {
        CVPixelBufferUnlockBaseAddress(frameBuffer.pixelBuffer, 0);
        frameBuffer.baseAddress = NULL;
    }
    (void)planes;
}

- (void)displayFrameBuffer:(void *)picture
{
    GenPlayerVLCFrameBuffer *frameBuffer = CFBridgingRelease(picture);
    if (frameBuffer == nil) {
        return;
    }

    BOOL attached = NO;
    NSTimeInterval minimumFrameInterval = 0;
    @synchronized (self) {
        attached = self.attached;
        minimumFrameInterval = self.minimumFrameInterval;
    }
    if (!attached) {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    BOOL shouldDeliver = YES;
    @synchronized (self) {
        if (minimumFrameInterval > 0 &&
            self.lastDeliveredFrameTime > 0 &&
            now - self.lastDeliveredFrameTime < minimumFrameInterval) {
            shouldDeliver = NO;
        } else {
            self.lastDeliveredFrameTime = now;
        }
    }
    if (!shouldDeliver) {
        return;
    }

    CVPixelBufferRef pixelBuffer = frameBuffer.pixelBuffer;
    if (pixelBuffer == NULL) {
        return;
    }

    int currentInFlight = atomic_fetch_add(&_inFlightFrameCount, 1);
    if (currentInFlight >= 2) {
        atomic_fetch_sub(&_inFlightFrameCount, 1);
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    
    dispatch_queue_t targetQueue = self.callbackQueue ?: dispatch_get_main_queue();
    dispatch_async(targetQueue, ^{
        GenPlayerVLCFrameBridgeFrameHandler handler = self.frameHandler;
        if (handler != nil && self.isAttached) {
            handler(pixelBuffer);
        }
        CVPixelBufferRelease(pixelBuffer);
        atomic_fetch_sub(&self->_inFlightFrameCount, 1);
    });
}

- (unsigned)configureWithChroma:(char *)chroma
                          width:(unsigned *)width
                         height:(unsigned *)height
                        pitches:(unsigned *)pitches
                          lines:(unsigned *)lines
{
    if (chroma == NULL || width == NULL || height == NULL || pitches == NULL || lines == NULL) {
        return 0;
    }

    CGFloat sourceWidth = MAX((CGFloat)*width, 1.0);
    CGFloat sourceHeight = MAX((CGFloat)*height, 1.0);
    CGFloat longestEdge = MAX(sourceWidth, sourceHeight);
    CGFloat scale = 1.0;
    if (self.maximumRenderWidth > 0 && longestEdge > (CGFloat)self.maximumRenderWidth) {
        scale = (CGFloat)self.maximumRenderWidth / longestEdge;
    }

    NSInteger resolvedWidth = MAX(2, (NSInteger)lrint(sourceWidth * scale));
    NSInteger resolvedHeight = MAX(2, (NSInteger)lrint(sourceHeight * scale));
    resolvedWidth = GenPlayerAlignUpInteger(resolvedWidth, 2);
    resolvedHeight = GenPlayerAlignUpInteger(resolvedHeight, 2);

    NSDictionary *pixelBufferAttributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(resolvedWidth),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(resolvedHeight),
        (__bridge NSString *)kCVPixelBufferBytesPerRowAlignmentKey: @(GenPlayerAlignUpInteger(resolvedWidth * 4, 64)),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
    };

    CVPixelBufferPoolRef pixelBufferPool = NULL;
    CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                  NULL,
                                                  (__bridge CFDictionaryRef)pixelBufferAttributes,
                                                  &pixelBufferPool);
    if (poolStatus != kCVReturnSuccess || pixelBufferPool == NULL) {
        return 0;
    }

    CVPixelBufferRef probeBuffer = NULL;
    CVReturn probeStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &probeBuffer);
    if (probeStatus != kCVReturnSuccess || probeBuffer == NULL) {
        CVPixelBufferPoolRelease(pixelBufferPool);
        return 0;
    }
    NSInteger resolvedPitch = (NSInteger)CVPixelBufferGetBytesPerRow(probeBuffer);
    CVPixelBufferRelease(probeBuffer);

    memcpy(chroma, "RV32", 4);
    *width = (unsigned)resolvedWidth;
    *height = (unsigned)resolvedHeight;
    pitches[0] = (unsigned)resolvedPitch;
    lines[0] = (unsigned)resolvedHeight;

    CGSize videoSize = CGSizeMake(resolvedWidth, resolvedHeight);
    @synchronized (self) {
        GenPlayerVLCFrameCallbackState *callbackState = self.callbackState;
        if (callbackState != nil) {
            @synchronized (callbackState) {
                if (callbackState.pixelBufferPool != NULL) {
                    CVPixelBufferPoolRelease(callbackState.pixelBufferPool);
                    callbackState.pixelBufferPool = NULL;
                }
                if (pixelBufferPool != NULL) {
                    CVPixelBufferPoolRetain(pixelBufferPool);
                    callbackState.pixelBufferPool = pixelBufferPool;
                }
                callbackState.frameWidth = (unsigned)resolvedWidth;
                callbackState.frameHeight = (unsigned)resolvedHeight;
                callbackState.framePitch = (unsigned)resolvedPitch;
                callbackState.attached = self.attached;
                callbackState.lastDeliveredFrameTime = 0;
            }
        }
        if (self.pixelBufferPool != NULL) {
            CVPixelBufferPoolRelease(self.pixelBufferPool);
        }
        self.pixelBufferPool = pixelBufferPool;
        self.frameWidth = (unsigned)resolvedWidth;
        self.frameHeight = (unsigned)resolvedHeight;
        self.framePitch = (unsigned)resolvedPitch;
        self.currentVideoSize = videoSize;
        self.lastDeliveredFrameTime = 0;
    }

    if (self.videoSizeHandler != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isAttached) {
                self.videoSizeHandler(videoSize);
            }
        });
    }

    return 1;
}

- (void)cleanupConfiguredFormat
{
    @synchronized (self) {
        if (self.pixelBufferPool != NULL) {
            CVPixelBufferPoolRelease(self.pixelBufferPool);
            self.pixelBufferPool = NULL;
        }
        self.frameWidth = 0;
        self.frameHeight = 0;
        self.framePitch = 0;
        self.currentVideoSize = CGSizeZero;
        self.lastDeliveredFrameTime = 0;
    }
}

@end

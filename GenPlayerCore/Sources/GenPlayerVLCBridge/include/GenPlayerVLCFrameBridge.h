#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

#if __has_include(<VLCKitSPM/VLCKitSPM.h>)
#import <VLCKitSPM/VLCKitSPM.h>
#elif TARGET_OS_OSX
#import <VLCKit/VLCKit.h>
#elif TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

typedef void (^GenPlayerVLCFrameBridgeFrameHandler)(CVPixelBufferRef pixelBuffer);
typedef void (^GenPlayerVLCFrameBridgeVideoSizeHandler)(CGSize size);

@interface GenPlayerVLCFrameBridge : NSObject

@property (nullable, nonatomic, copy) GenPlayerVLCFrameBridgeFrameHandler frameHandler;
@property (nullable, nonatomic, copy) GenPlayerVLCFrameBridgeVideoSizeHandler videoSizeHandler;
@property (nonatomic) NSInteger maximumRenderWidth;
@property (nonatomic) NSTimeInterval minimumFrameInterval;
/// Queue on which frameHandler is invoked. Defaults to the main queue.
@property (nullable, nonatomic, strong) dispatch_queue_t callbackQueue;
@property (readonly, nonatomic, getter=isAttached) BOOL attached;
@property (readonly, nonatomic) CGSize currentVideoSize;

- (BOOL)attachToMediaPlayer:(VLCMediaPlayer *)mediaPlayer error:(NSError * _Nullable * _Nullable)error;
- (void)detach;

@end

NS_ASSUME_NONNULL_END

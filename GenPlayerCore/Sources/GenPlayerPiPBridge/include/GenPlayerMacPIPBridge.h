#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol GenPlayerMacPIPBridgeDelegate <NSObject>
@optional
- (void)pipBridgeDidClose;
- (void)pipBridgeRequestRestore;
- (void)pipBridgeRequestPlay;
- (void)pipBridgeRequestPause;
- (void)pipBridgeRequestStop;
- (void)pipBridgeRequestSeekByInterval:(NSTimeInterval)interval;
@end

@interface GenPlayerMacPIPBridge : NSObject

@property (nonatomic, weak, nullable) id<GenPlayerMacPIPBridgeDelegate> delegate;
@property (nonatomic, readonly) BOOL isPIPActive;

+ (BOOL)isPIPSupported;

- (BOOL)startPIPWithVideoView:(NSView *)videoView
                  aspectRatio:(NSSize)aspectRatio
                     isPlaying:(BOOL)isPlaying
                        title:(nullable NSString *)title;

- (void)stopPIP;
- (void)setPlaying:(BOOL)playing;
- (void)updatePlaybackProgress:(NSTimeInterval)elapsedTime duration:(NSTimeInterval)duration isPlaying:(BOOL)isPlaying;

@end

NS_ASSUME_NONNULL_END
#endif

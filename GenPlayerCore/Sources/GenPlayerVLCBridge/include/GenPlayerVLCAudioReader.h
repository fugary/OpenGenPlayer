#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX || (TARGET_OS_IOS && !TARGET_OS_TV)
NS_ASSUME_NONNULL_BEGIN
/// Independent, silent file demuxing. Never attaches to a playback window/player.
@interface GenPlayerVLCAudioReader : NSObject
- (void)cancel;
- (nullable NSDictionary<NSString *, id> *)inspectURL:(NSURL *)url error:(NSError **)error;
- (BOOL)decodePCMURL:(NSURL *)url trackID:(int)trackID toURL:(NSURL *)output error:(NSError **)error;
- (BOOL)remuxURL:(NSURL *)url trackID:(int)trackID toURL:(NSURL *)output error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
#endif

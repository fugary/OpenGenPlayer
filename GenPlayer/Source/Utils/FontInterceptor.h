//
//  FontInterceptor.h
//  GenPlayer
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FontInterceptor : NSObject

/// Sets up the font interceptor. It uses fishhook to swizzle CoreText font creation
/// functions to bypass the iOS 18 new PingFang .hvgl format issue when libass/FreeType
/// attempts to load CJK fallback fonts.
+ (void)setup;

@end

NS_ASSUME_NONNULL_END

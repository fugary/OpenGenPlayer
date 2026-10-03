//
//  FontInterceptor.m
//  GenPlayer
//

#import "FontInterceptor.h"
#import "fishhook.h"
#import <CoreText/CoreText.h>

static CTFontRef (*orig_CTFontCreateWithName)(CFStringRef name, CGFloat size, const CGAffineTransform *matrix);
static CTFontRef (*orig_CTFontCreateWithNameAndOptions)(CFStringRef name, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options);
static CTFontRef (*orig_CTFontCreateWithFontDescriptor)(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix);
static CTFontRef (*orig_CTFontCreateWithFontDescriptorAndOptions)(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options);
static CTFontRef (*orig_CTFontCreateForString)(CTFontRef currentFont, CFStringRef string, CFRange range);

static BOOL isBlacklistedFontName(CFStringRef name) {
    if (!name) return NO;
    NSString *fontName = [(__bridge NSString *)name lowercaseString];
    
    // Explicitly target PingFang fonts, Chinese defaults, and typical substitutions 
    // that crash FreeType or rely on .hvgl internally.
    if ([fontName containsString:@"pingfang"] ||
        [fontName containsString:@".apple"] || 
        [fontName containsString:@"heiti"] ||
        [fontName containsString:@"simhei"] ||
        [fontName containsString:@"kaiti"] ||
        [fontName containsString:@"hiragino"] ||
        [fontName containsString:@"yahei"] ||
        [fontName containsString:@"songti"] ||
        [fontName containsString:@"stsong"] ||
        [fontName containsString:@"weiruan"] ||
        [fontName containsString:@"microsoft"] ||
        [fontName containsString:@"wqy"] ||
        [fontName containsString:@"wenquanyi"]) {
        return YES;
    }
    return NO;
}

static CTFontRef my_CTFontCreateWithName(CFStringRef name, CGFloat size, const CGAffineTransform *matrix) {
    if (isBlacklistedFontName(name)) {
        CFStringRef replacement = CFSTR("SourceHanSansSC-Regular");
        return orig_CTFontCreateWithName(replacement, size, matrix);
    }
    return orig_CTFontCreateWithName(name, size, matrix);
}

static CTFontRef my_CTFontCreateWithNameAndOptions(CFStringRef name, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options) {
    if (isBlacklistedFontName(name)) {
        CFStringRef replacement = CFSTR("SourceHanSansSC-Regular");
        return orig_CTFontCreateWithNameAndOptions(replacement, size, matrix, options);
    }
    return orig_CTFontCreateWithNameAndOptions(name, size, matrix, options);
}

static CTFontRef my_CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix) {
    if (descriptor) {
        CFStringRef name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
        CFStringRef family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
        
        BOOL shouldHijack = NO;
        if (name && isBlacklistedFontName(name)) {
            shouldHijack = YES;
        } else if (family && isBlacklistedFontName(family)) {
            shouldHijack = YES;
        }
        
        if (name) CFRelease(name);
        if (family) CFRelease(family);
        
        if (shouldHijack) {
            CFStringRef replacement = CFSTR("SourceHanSansSC-Regular");
            return orig_CTFontCreateWithName(replacement, size, matrix);
        }
    }
    return orig_CTFontCreateWithFontDescriptor(descriptor, size, matrix);
}

static CTFontRef my_CTFontCreateWithFontDescriptorAndOptions(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options) {
    if (descriptor) {
        CFStringRef name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
        CFStringRef family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
        
        BOOL shouldHijack = NO;
        if (name && isBlacklistedFontName(name)) shouldHijack = YES;
        else if (family && isBlacklistedFontName(family)) shouldHijack = YES;
        
        if (name) CFRelease(name);
        if (family) CFRelease(family);
        
        if (shouldHijack) {
            CFStringRef replacement = CFSTR("SourceHanSansSC-Regular");
            return orig_CTFontCreateWithNameAndOptions(replacement, size, matrix, options);
        }
    }
    return orig_CTFontCreateWithFontDescriptorAndOptions(descriptor, size, matrix, options);
}

static CTFontRef my_CTFontCreateForString(CTFontRef currentFont, CFStringRef string, CFRange range) {
    // If libass asks CoreText "Give me a fallback font for this string",
    // CoreText will likely return PingFang. We hook the result.
    CTFontRef fallback = orig_CTFontCreateForString(currentFont, string, range);
    if (fallback) {
        CFStringRef fallbackName = CTFontCopyName(fallback, kCTFontPostScriptNameKey);
        if (fallbackName) {
            if (isBlacklistedFontName(fallbackName)) {
                // If the system chose a problematic font as a fallback, substitute it
                CGFloat size = CTFontGetSize(fallback);
                CGAffineTransform matrix = CTFontGetMatrix(fallback);
                CFRelease(fallbackName);
                CFRelease(fallback); // Release original fallback PingFang
                
                CFStringRef replacement = CFSTR("SourceHanSansSC-Regular");
                return orig_CTFontCreateWithName(replacement, size, &matrix);
            }
            CFRelease(fallbackName);
        }
    }
    return fallback;
}

@implementation FontInterceptor

+ (void)setup {
    if (@available(iOS 18.0, tvOS 18.0, *)) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            struct rebinding rebinds[] = {
                {"CTFontCreateWithName", (void *)my_CTFontCreateWithName, (void **)&orig_CTFontCreateWithName},
                {"CTFontCreateWithNameAndOptions", (void *)my_CTFontCreateWithNameAndOptions, (void **)&orig_CTFontCreateWithNameAndOptions},
                {"CTFontCreateWithFontDescriptor", (void *)my_CTFontCreateWithFontDescriptor, (void **)&orig_CTFontCreateWithFontDescriptor},
                {"CTFontCreateWithFontDescriptorAndOptions", (void *)my_CTFontCreateWithFontDescriptorAndOptions, (void **)&orig_CTFontCreateWithFontDescriptorAndOptions},
                {"CTFontCreateForString", (void *)my_CTFontCreateForString, (void **)&orig_CTFontCreateForString}
            };
            rebind_symbols(rebinds, 5);
        });
    }
}

@end

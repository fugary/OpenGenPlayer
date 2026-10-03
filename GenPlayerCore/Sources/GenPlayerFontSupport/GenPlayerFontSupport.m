#import "GenPlayerFontSupport.h"
#import "fishhook.h"

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

static CTFontRef (*genplayer_orig_CTFontCreateWithName)(CFStringRef name, CGFloat size, const CGAffineTransform *matrix);
static CTFontRef (*genplayer_orig_CTFontCreateWithNameAndOptions)(CFStringRef name, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options);
static CTFontRef (*genplayer_orig_CTFontCreateWithFontDescriptor)(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix);
static CTFontRef (*genplayer_orig_CTFontCreateWithFontDescriptorAndOptions)(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options);
static CTFontRef (*genplayer_orig_CTFontCreateForString)(CTFontRef currentFont, CFStringRef string, CFRange range);

BOOL g_GenPlayerCJKFontInterceptorEnabled = NO;

static CFStringRef GenPlayerCJKReplacementFontName(void) {
    return CFSTR("SourceHanSansSC-Regular");
}

static BOOL GenPlayerFontNameShouldUseCJKFallback(CFStringRef name) {
    if (!name) {
        return NO;
    }

    NSString *fontName = [(__bridge NSString *)name lowercaseString];
    return [fontName containsString:@"pingfang"] ||
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
        [fontName containsString:@"wenquanyi"] ||
        [fontName containsString:@"lastresort"];
}

static BOOL GenPlayerStringContainsCJK(CFStringRef string, CFRange range) {
    if (!string) {
        return NO;
    }

    CFIndex length = CFStringGetLength(string);
    if (length <= 0) {
        return NO;
    }

    CFIndex start = 0;
    CFIndex end = length;
    if (range.location != kCFNotFound && range.length > 0) {
        start = MAX((CFIndex)0, range.location);
        end = MIN(length, start + range.length);
        if (start >= end) {
            start = 0;
            end = length;
        }
    }

    for (CFIndex index = start; index < end; index++) {
        UniChar high = CFStringGetCharacterAtIndex(string, index);
        UTF32Char scalar = high;
        if (CFStringIsSurrogateHighCharacter(high) && index + 1 < end) {
            UniChar low = CFStringGetCharacterAtIndex(string, index + 1);
            if (CFStringIsSurrogateLowCharacter(low)) {
                scalar = CFStringGetLongCharacterForSurrogatePair(high, low);
                index += 1;
            }
        }

        if ((scalar >= 0x3400 && scalar <= 0x4DBF) ||
            (scalar >= 0x4E00 && scalar <= 0x9FFF) ||
            (scalar >= 0xF900 && scalar <= 0xFAFF) ||
            (scalar >= 0x3040 && scalar <= 0x30FF) ||
            (scalar >= 0xAC00 && scalar <= 0xD7AF)) {
            return YES;
        }
    }

    return NO;
}

static BOOL GenPlayerFontCanRenderCJKInString(CTFontRef font, CFStringRef string, CFRange range) {
    if (!font || !string) {
        return NO;
    }

    CFIndex length = CFStringGetLength(string);
    CFIndex start = 0;
    CFIndex end = length;
    if (range.location != kCFNotFound && range.length > 0) {
        start = MAX((CFIndex)0, range.location);
        end = MIN(length, start + range.length);
        if (start >= end) {
            start = 0;
            end = length;
        }
    }

    for (CFIndex index = start; index < end; index++) {
        UniChar character = CFStringGetCharacterAtIndex(string, index);
        UTF32Char scalar = character;
        if (CFStringIsSurrogateHighCharacter(character) && index + 1 < end) {
            UniChar low = CFStringGetCharacterAtIndex(string, index + 1);
            if (CFStringIsSurrogateLowCharacter(low)) {
                scalar = CFStringGetLongCharacterForSurrogatePair(character, low);
                index += 1;
            }
        }

        BOOL isCJK =
            (scalar >= 0x3400 && scalar <= 0x4DBF) ||
            (scalar >= 0x4E00 && scalar <= 0x9FFF) ||
            (scalar >= 0xF900 && scalar <= 0xFAFF) ||
            (scalar >= 0x3040 && scalar <= 0x30FF) ||
            (scalar >= 0xAC00 && scalar <= 0xD7AF);
        if (!isCJK || scalar > 0xFFFF) {
            continue;
        }

        CGGlyph glyph = 0;
        UniChar c = (UniChar)scalar;
        if (!CTFontGetGlyphsForCharacters(font, &c, &glyph, 1) || glyph == 0) {
            return NO;
        }
    }

    return YES;
}

static CTFontRef GenPlayerCreateReplacementFont(CGFloat size, const CGAffineTransform *matrix) {
    if (!genplayer_orig_CTFontCreateWithName) {
        return NULL;
    }
    return genplayer_orig_CTFontCreateWithName(GenPlayerCJKReplacementFontName(), size, matrix);
}

static CTFontRef genplayer_CTFontCreateWithName(CFStringRef name, CGFloat size, const CGAffineTransform *matrix) {
    if (g_GenPlayerCJKFontInterceptorEnabled && GenPlayerFontNameShouldUseCJKFallback(name)) {
        CTFontRef font = GenPlayerCreateReplacementFont(size, matrix);
        if (font) {
            return font;
        }
    }
    return genplayer_orig_CTFontCreateWithName ? genplayer_orig_CTFontCreateWithName(name, size, matrix) : NULL;
}

static CTFontRef genplayer_CTFontCreateWithNameAndOptions(CFStringRef name, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options) {
    if (g_GenPlayerCJKFontInterceptorEnabled && GenPlayerFontNameShouldUseCJKFallback(name) && genplayer_orig_CTFontCreateWithNameAndOptions) {
        CTFontRef font = genplayer_orig_CTFontCreateWithNameAndOptions(GenPlayerCJKReplacementFontName(), size, matrix, options);
        if (font) {
            return font;
        }
    }
    return genplayer_orig_CTFontCreateWithNameAndOptions ? genplayer_orig_CTFontCreateWithNameAndOptions(name, size, matrix, options) : NULL;
}

static BOOL GenPlayerDescriptorShouldUseCJKFallback(CTFontDescriptorRef descriptor) {
    if (!descriptor) {
        return NO;
    }

    BOOL shouldUseFallback = NO;
    CFStringRef name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
    CFStringRef family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
    if (name && GenPlayerFontNameShouldUseCJKFallback(name)) {
        shouldUseFallback = YES;
    } else if (family && GenPlayerFontNameShouldUseCJKFallback(family)) {
        shouldUseFallback = YES;
    }

    if (name) {
        CFRelease(name);
    }
    if (family) {
        CFRelease(family);
    }
    return shouldUseFallback;
}

static CTFontRef genplayer_CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix) {
    if (g_GenPlayerCJKFontInterceptorEnabled && GenPlayerDescriptorShouldUseCJKFallback(descriptor)) {
        CTFontRef font = GenPlayerCreateReplacementFont(size, matrix);
        if (font) {
            return font;
        }
    }
    return genplayer_orig_CTFontCreateWithFontDescriptor ? genplayer_orig_CTFontCreateWithFontDescriptor(descriptor, size, matrix) : NULL;
}

static CTFontRef genplayer_CTFontCreateWithFontDescriptorAndOptions(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options) {
    if (g_GenPlayerCJKFontInterceptorEnabled && GenPlayerDescriptorShouldUseCJKFallback(descriptor) && genplayer_orig_CTFontCreateWithNameAndOptions) {
        CTFontRef font = genplayer_orig_CTFontCreateWithNameAndOptions(GenPlayerCJKReplacementFontName(), size, matrix, options);
        if (font) {
            return font;
        }
    }
    return genplayer_orig_CTFontCreateWithFontDescriptorAndOptions ? genplayer_orig_CTFontCreateWithFontDescriptorAndOptions(descriptor, size, matrix, options) : NULL;
}

static CTFontRef genplayer_CTFontCreateForString(CTFontRef currentFont, CFStringRef string, CFRange range) {
    if (!g_GenPlayerCJKFontInterceptorEnabled) {
        return genplayer_orig_CTFontCreateForString ? genplayer_orig_CTFontCreateForString(currentFont, string, range) : NULL;
    }
    CTFontRef fallback = genplayer_orig_CTFontCreateForString ? genplayer_orig_CTFontCreateForString(currentFont, string, range) : NULL;
    BOOL containsCJK = GenPlayerStringContainsCJK(string, range);

    if (fallback) {
        CFStringRef fallbackName = CTFontCopyName(fallback, kCTFontPostScriptNameKey);
        BOOL shouldReplace =
            containsCJK &&
            ((fallbackName && GenPlayerFontNameShouldUseCJKFallback(fallbackName)) ||
             !GenPlayerFontCanRenderCJKInString(fallback, string, range));
        if (fallbackName) {
            CFRelease(fallbackName);
        }

        if (shouldReplace) {
            CGFloat size = CTFontGetSize(fallback);
            CGAffineTransform matrix = CTFontGetMatrix(fallback);
            CFRelease(fallback);

            CTFontRef replacement = GenPlayerCreateReplacementFont(size, &matrix);
            if (replacement) {
                return replacement;
            }
        }
        return fallback;
    }

    if (containsCJK && currentFont) {
        CGFloat size = CTFontGetSize(currentFont);
        CGAffineTransform matrix = CTFontGetMatrix(currentFont);
        CTFontRef replacement = GenPlayerCreateReplacementFont(size, &matrix);
        if (replacement) {
            return replacement;
        }
    }

    return fallback;
}

void GenPlayerInstallCJKFontInterceptor(void) {
    if (@available(iOS 18.0, tvOS 18.0, macOS 15.0, *)) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            struct rebinding rebinds[] = {
                {"CTFontCreateWithName", (void *)genplayer_CTFontCreateWithName, (void **)&genplayer_orig_CTFontCreateWithName},
                {"CTFontCreateWithNameAndOptions", (void *)genplayer_CTFontCreateWithNameAndOptions, (void **)&genplayer_orig_CTFontCreateWithNameAndOptions},
                {"CTFontCreateWithFontDescriptor", (void *)genplayer_CTFontCreateWithFontDescriptor, (void **)&genplayer_orig_CTFontCreateWithFontDescriptor},
                {"CTFontCreateWithFontDescriptorAndOptions", (void *)genplayer_CTFontCreateWithFontDescriptorAndOptions, (void **)&genplayer_orig_CTFontCreateWithFontDescriptorAndOptions},
                {"CTFontCreateForString", (void *)genplayer_CTFontCreateForString, (void **)&genplayer_orig_CTFontCreateForString}
            };
            genplayer_rebind_symbols(rebinds, 5);
        });
    }
}

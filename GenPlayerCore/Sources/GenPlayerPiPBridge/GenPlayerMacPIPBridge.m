#import "GenPlayerMacPIPBridge.h"

#if TARGET_OS_OSX
#import <objc/runtime.h>

@protocol PIPViewControllerDelegate <NSObject>
@optional
- (void)pipWillClose:(id)pip;
- (void)pipDidClose:(id)pip;
- (void)pipActionClose:(id)pip;
- (void)pipActionRestore:(id)pip;
- (void)pipActionPlay:(id)pip;
- (void)pipActionPause:(id)pip;
- (void)pipActionStop:(id)pip;
- (void)pipAction:(id)pip setPlaying:(BOOL)playing;
- (void)pipAction:(id)pip skipInterval:(NSTimeInterval)interval;
@end

@interface GenPlayerMacPIPBridge () <PIPViewControllerDelegate>
@property (nonatomic, strong, nullable) id pipViewController;
@property (nonatomic, strong, nullable) NSViewController *pipContentViewController;
@property (nonatomic, weak, nullable) NSView *originalVideoView;
@property (nonatomic, weak, nullable) NSView *originalSuperview;
@property (nonatomic) NSRect originalFrame;
@property (nonatomic) BOOL isPIPActiveInternal;
@property (nonatomic) BOOL isRestoringInternal;
@end

@implementation GenPlayerMacPIPBridge

+ (BOOL)isPIPSupported {
    static BOOL loaded = NO;
    static BOOL supported = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PIP.framework"];
        if ([bundle load]) {
            Class cls = NSClassFromString(@"PIPViewController");
            if (cls) {
                supported = YES;
            }
        }
    });
    return supported;
}

- (BOOL)startPIPWithVideoView:(NSView *)videoView
                  aspectRatio:(NSSize)aspectRatio
                     isPlaying:(BOOL)isPlaying
                        title:(NSString *)title {
    if (![GenPlayerMacPIPBridge isPIPSupported]) return NO;
    if (self.isPIPActiveInternal) return YES;

    Class pipClass = NSClassFromString(@"PIPViewController");
    if (!pipClass) return NO;

    self.originalVideoView = videoView;
    self.originalSuperview = videoView.superview;
    self.originalFrame = videoView.frame;
    self.isRestoringInternal = NO;

    id pip = [[pipClass alloc] init];
    self.pipViewController = pip;

    [pip setValue:self forKey:@"delegate"];
    if (title) {
        [pip setValue:title forKey:@"title"];
    }
    [pip setValue:[NSValue valueWithSize:aspectRatio] forKey:@"aspectRatio"];
    [pip setValue:@(isPlaying) forKey:@"playing"];

    NSViewController *contentVC = [[NSViewController alloc] init];
    contentVC.view = videoView;
    self.pipContentViewController = contentVC;

    SEL presentSel = NSSelectorFromString(@"presentViewControllerAsPictureInPicture:");
    if ([pip respondsToSelector:presentSel]) {
        IMP imp = [pip methodForSelector:presentSel];
        void (*func)(id, SEL, id) = (void *)imp;
        func(pip, presentSel, contentVC);
        self.isPIPActiveInternal = YES;
        return YES;
    }
    return NO;
}

- (void)stopPIP {
    if (!self.isPIPActiveInternal || !self.pipViewController) return;

    id pip = self.pipViewController;
    NSViewController *contentVC = self.pipContentViewController;
    if (!contentVC) return;

    // Set the window and rect that the PiP should animate (fly) back to.
    // This enables the "flyback" animation when the user restores PiP.
    NSView *originalView = self.originalSuperview;
    if (originalView) {
        NSWindow *window = originalView.window;
        if (window) {
            [pip setValue:window forKey:@"replacementWindow"];
            NSRect rectInWindow = [originalView convertRect:originalView.bounds toView:nil];
            [pip setValue:[NSValue valueWithRect:rectInWindow] forKey:@"replacementRect"];
        }
    }

    // Use dismissViewControllerWithFlyback: (same path as IINA's pip.dismiss(pipVideo)).
    // This does NOT take a completion block, avoiding the nil-block crash in
    // dismissPictureInPictureWithCompletionHandler: when passed nil.
    SEL flybackSel = NSSelectorFromString(@"dismissViewControllerWithFlyback:");
    if ([pip respondsToSelector:flybackSel]) {
        IMP imp = [pip methodForSelector:flybackSel];
        void (*func)(id, SEL, id) = (void *)imp;
        func(pip, flybackSel, contentVC);
    }
}


- (BOOL)isPIPActive {
    return self.isPIPActiveInternal;
}

- (void)setPlaying:(BOOL)playing {
    if (self.pipViewController) {
        [self.pipViewController setValue:@(playing) forKey:@"playing"];
    }
}

- (void)updatePlaybackProgress:(NSTimeInterval)elapsedTime duration:(NSTimeInterval)duration isPlaying:(BOOL)isPlaying {
    if (!self.pipViewController) return;
    SEL updateSel = NSSelectorFromString(@"updatePlaybackStateUsingBlock:");
    if ([self.pipViewController respondsToSelector:updateSel]) {
        void (^updateBlock)(id state) = ^(id state) {
            [state setValue:@(1) forKey:@"contentType"];
            [state setValue:@(duration) forKey:@"contentDuration"];
            SEL rateSel = NSSelectorFromString(@"setPlaybackRate:elapsedTime:timeControlStatus:");
            if ([state respondsToSelector:rateSel]) {
                IMP imp = [state methodForSelector:rateSel];
                void (*func)(id, SEL, double, NSTimeInterval, NSInteger) = (void *)imp;
                func(state, rateSel, isPlaying ? 1.0 : 0.0, elapsedTime, isPlaying ? 2 : 0);
            }
        };
        IMP imp = [self.pipViewController methodForSelector:updateSel];
        void (*func)(id, SEL, id) = (void *)imp;
        func(self.pipViewController, updateSel, updateBlock);
    }
}

#pragma mark - PIPViewControllerDelegate

- (void)restoreOriginalVideoView {
    if (self.originalVideoView && self.originalSuperview && self.originalVideoView.superview != self.originalSuperview) {
        [self.originalSuperview addSubview:self.originalVideoView];
        self.originalVideoView.frame = self.originalSuperview.bounds;
        self.originalVideoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
}

- (void)pipWillClose:(id)pip {
    // Do NOT manipulate the video view hierarchy here.
    // PIPViewController may still be running its dismiss animation and accessing the content view.
    // Moving the view mid-animation causes EXC_BAD_ACCESS inside PIP.framework.
    // Video view restoration is handled in pipDidClose: dispatch_async (after animation completes).
}

- (void)pipDidClose:(id)pip {
    // Keep strong refs on the stack so PIP.framework's weak delegate remains valid
    // until the entire framework teardown call stack unwinds (dispatch_async ensures
    // these objects are released only after PIP.framework returns fully).
    GenPlayerMacPIPBridge *keepSelf = self;
    id keepPip = self.pipViewController;
    id keepVC = self.pipContentViewController;

    dispatch_async(dispatch_get_main_queue(), ^{
        [keepSelf restoreOriginalVideoView];
        keepSelf.isPIPActiveInternal = NO;
        keepSelf.pipViewController = nil;
        keepSelf.pipContentViewController = nil;

        if ([keepSelf.delegate respondsToSelector:@selector(pipBridgeDidClose)]) {
            [keepSelf.delegate pipBridgeDidClose];
        }

        // Extend lifetime to next runloop tick to be safe
        (void)keepPip;
        (void)keepVC;
    });
}

- (void)pipActionClose:(id)pip {
    self.isRestoringInternal = NO;
    // Defer to avoid re-entrant call into PIPViewController from within its own delegate callback
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopPIP];
    });
}

- (void)pipActionRestore:(id)pip {
    // PIPViewController does NOT self-dismiss on restore - we must call stopPIP.
    // Deferred to next runloop to avoid re-entering PIPViewController from within its callback.
    // Video view is only moved AFTER pipDidClose: fires (dispatch_async in pipDidClose:),
    // so the animation completes safely before we touch the view hierarchy.
    self.isRestoringInternal = YES;
    if ([self.delegate respondsToSelector:@selector(pipBridgeRequestRestore)]) {
        [self.delegate pipBridgeRequestRestore];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopPIP];
    });
}

- (void)pipActionPlay:(id)pip {
    if ([self.delegate respondsToSelector:@selector(pipBridgeRequestPlay)]) {
        [self.delegate pipBridgeRequestPlay];
    }
}

- (void)pipActionPause:(id)pip {
    if ([self.delegate respondsToSelector:@selector(pipBridgeRequestPause)]) {
        [self.delegate pipBridgeRequestPause];
    }
}

- (void)pipActionStop:(id)pip {
    if ([self.delegate respondsToSelector:@selector(pipBridgeRequestStop)]) {
        [self.delegate pipBridgeRequestStop];
    }
}

- (void)pipAction:(id)pip setPlaying:(BOOL)playing {
    if (playing) {
        if ([self.delegate respondsToSelector:@selector(pipBridgeRequestPlay)]) {
            [self.delegate pipBridgeRequestPlay];
        }
    } else {
        if ([self.delegate respondsToSelector:@selector(pipBridgeRequestPause)]) {
            [self.delegate pipBridgeRequestPause];
        }
    }
}

- (void)pipAction:(id)pip skipInterval:(NSTimeInterval)interval {
    if ([self.delegate respondsToSelector:@selector(pipBridgeRequestSeekByInterval:)]) {
        [self.delegate pipBridgeRequestSeekByInterval:interval];
    }
}

@end
#endif

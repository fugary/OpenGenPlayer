#import "GenPlayerVLCAudioReader.h"
#if TARGET_OS_OSX || (TARGET_OS_IOS && !TARGET_OS_TV)
#if TARGET_OS_OSX
#import <VLCKit/vlc/libvlc.h>
#import <VLCKit/vlc/libvlc_media.h>
#import <VLCKit/vlc/libvlc_renderer_discoverer.h>
#import <VLCKit/vlc/libvlc_media_player.h>
#else
#import <MobileVLCKit/vlc/libvlc.h>
#import <MobileVLCKit/vlc/libvlc_media.h>
#import <MobileVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <MobileVLCKit/vlc/libvlc_media_player.h>
#endif
#import <stdatomic.h>
#import <unistd.h>

@implementation GenPlayerVLCAudioReader {
    atomic_bool _cancelled;
}
- (instancetype)init { if ((self = [super init])) atomic_init(&_cancelled, false); return self; }
- (void)cancel { atomic_store(&_cancelled, true); }
- (void)setFailure:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"GenPlayerVLCAudioReader" code:atomic_load(&_cancelled) ? NSUserCancelledError : NSFileReadCorruptFileError userInfo:nil];
}
- (libvlc_instance_t *)newLibrary {
    const char *options[] = {"--intf=dummy", "--no-video", "--no-spu", "--no-osd", "--quiet"};
    return libvlc_new(5, options);
}
- (NSDictionary<NSString *, id> *)inspectURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL || atomic_load(&_cancelled)) { [self setFailure:error]; return nil; }
    libvlc_instance_t *library = [self newLibrary];
    if (!library) { [self setFailure:error]; return nil; }
    libvlc_media_t *media = libvlc_media_new_path(library, url.fileSystemRepresentation);
    NSMutableArray *audio = [NSMutableArray array];
    int64_t duration = -1;
    if (media && libvlc_media_parse_with_options(media, libvlc_media_parse_local, 5000) == 0) {
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 6;
        while (!atomic_load(&_cancelled) && NSProcessInfo.processInfo.systemUptime < deadline) {
            libvlc_media_parsed_status_t status = libvlc_media_get_parsed_status(media);
            if (status == libvlc_media_parsed_status_done) {
                duration = libvlc_media_get_duration(media);
                libvlc_media_track_t **tracks = NULL;
                unsigned count = libvlc_media_tracks_get(media, &tracks);
                for (unsigned i = 0; i < count; i++) {
                    libvlc_media_track_t *track = tracks[i];
                    if (track->i_type != libvlc_track_audio) continue;
                    uint32_t codec = track->i_codec;
                    char name[5] = {codec & 255, (codec >> 8) & 255, (codec >> 16) & 255, (codec >> 24) & 255, 0};
                    [audio addObject:@{@"id": @(track->i_id), @"language": track->psz_language ? ([NSString stringWithUTF8String:track->psz_language] ?: @"") : @"",
                                       @"codec": [NSString stringWithUTF8String:name] ?: @""}];
                }
                libvlc_media_tracks_release(tracks, count);
                break;
            }
            if (status == libvlc_media_parsed_status_failed || status == libvlc_media_parsed_status_timeout) break;
            usleep(10000);
        }
        libvlc_media_parse_stop(media);
    }
    if (media) libvlc_media_release(media);
    libvlc_release(library);
    if (duration <= 0 || !audio.count || atomic_load(&_cancelled)) { [self setFailure:error]; return nil; }
    return @{@"duration": @(duration / 1000.0), @"tracks": audio};
}
- (BOOL)remuxURL:(NSURL *)url trackID:(int)trackID toURL:(NSURL *)output error:(NSError **)error {
    return [self exportURL:url trackID:trackID toURL:output decodePCM:NO error:error];
}
- (BOOL)decodePCMURL:(NSURL *)url trackID:(int)trackID toURL:(NSURL *)output error:(NSError **)error {
    return [self exportURL:url trackID:trackID toURL:output decodePCM:YES error:error];
}
- (BOOL)exportURL:(NSURL *)url trackID:(int)trackID toURL:(NSURL *)output decodePCM:(BOOL)decodePCM error:(NSError **)error {
    if (!url.isFileURL || !output.isFileURL || atomic_load(&_cancelled)) { [self setFailure:error]; return NO; }
    libvlc_instance_t *library = [self newLibrary];
    if (!library) { [self setFailure:error]; return NO; }
    libvlc_media_t *media = libvlc_media_new_path(library, url.fileSystemRepresentation);
    libvlc_media_player_t *player = NULL;
    BOOL finished = NO;
    if (media) {
        NSString *path = [[output.path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        // Keep the input sample rate. VLC's fallback "ugly" resampler rounds each DTS
        // packet independently (48 -> 16 kHz loses ~1.87 seconds in an 8-minute clip).
        // AVFoundation performs continuous, time-aligned resampling for each ASR chunk.
        NSString *sout = decodePCM
            ? [NSString stringWithFormat:@":sout=#transcode{acodec=s16l,channels=1}:std{access=file,mux=wav,dst='%@'}", path]
            : [NSString stringWithFormat:@":sout=#std{access=file,mux=mp4,dst='%@'}", path];
        libvlc_media_add_option(media, sout.UTF8String);
        libvlc_media_add_option(media, ":no-sout-video");
        libvlc_media_add_option(media, ":no-sout-spu");
        libvlc_media_add_option(media, ":no-sout-all");
        libvlc_media_add_option(media, [[NSString stringWithFormat:@":audio-track-id=%d", trackID] UTF8String]);
        player = libvlc_media_player_new_from_media(media);
        if (player && libvlc_media_player_play(player) == 0) {
            NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 120;
            while (!atomic_load(&_cancelled) && NSProcessInfo.processInfo.systemUptime < deadline) {
                libvlc_state_t state = libvlc_media_player_get_state(player);
                if (state == libvlc_Ended) { finished = YES; break; }
                if (state == libvlc_Error) break;
                // NSURL caches resource values; query fresh file attributes while the muxer grows the file.
                NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:output.path error:nil];
                if (attributes.fileSize > 512ull * 1024 * 1024) break;
                usleep(10000);
            }
        }
    }
    // Stop/join before closing the muxer or allowing cancellation to remove the temporary file.
    if (player) { libvlc_media_player_stop(player); libvlc_media_player_release(player); }
    if (media) libvlc_media_release(media);
    libvlc_release(library);
    unsigned long long finalSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:output.path error:nil] fileSize];
    if (!finished || atomic_load(&_cancelled) || finalSize == 0 || finalSize > 512ull * 1024 * 1024) {
        [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
        [self setFailure:error];
        return NO;
    }
    return YES;
}
@end
#endif

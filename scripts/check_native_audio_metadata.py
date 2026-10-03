#!/usr/bin/env python3
"""Read synthetic tagged audio using production metadata extraction and AVFoundation.
No App/window/audio output, no user media, and no VLC dependency.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
ffmpeg = sys.argv[1] if len(sys.argv) > 1 else shutil.which('ffmpeg')
if not ffmpeg:
    raise SystemExit('Pass a local ffmpeg executable to generate temporary fixtures.')
source = (root / 'GenPlayer/Source/Services/VLCPlaybackService+Extensions.swift').read_text()
model = source[source.index('    private struct ExtractedAudioMetadata {'):source.index('    func applyMPVAudioMetadata(')]
parser = source[source.index('    private func extractAudioMetadata('):source.index('    private func hasMeaningfulMetadataText(')]
swift = '''import Foundation
import AppKit
import AVFoundation
typealias UIImage = NSImage
struct Reader {
''' + (model + parser).replace('private ', '') + '''
}
@main struct Check {
    static func main() async throws {
        let reader = Reader()
        for path in CommandLine.arguments.dropFirst() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            var items = try await asset.load(.commonMetadata)
            for format in try await asset.load(.availableMetadataFormats) {
                items += try await asset.loadMetadata(for: format)
            }
            // Container metadata order must not let generic creator/artist values
            // overwrite dedicated album artist or composer tags.
            for ordered in [items, Array(items.reversed())] {
                let metadata = reader.extractAudioMetadata(from: ordered)
                print(URL(fileURLWithPath: path).lastPathComponent,
                      metadata.title ?? "nil", metadata.artist ?? "nil", metadata.album ?? "nil",
                      metadata.albumArtist ?? "nil", metadata.composer ?? "nil", metadata.artwork != nil)
                fflush(stdout)
                precondition(metadata.title == "Fixture Title")
                precondition(metadata.artist == "Fixture Artist")
                precondition(metadata.album == "Fixture Album")
                precondition(metadata.albumArtist == "Fixture Album Artist")
                precondition(metadata.composer == "Fixture Composer")
                precondition(metadata.artwork != nil)
            }
        }
        print("PASS: real AVFoundation tagged M4A/MP3 labels and artwork, both metadata orders")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='genplayer-native-metadata-') as folder:
    tmp = pathlib.Path(folder)
    cover = tmp / 'cover.ppm'
    cover.write_bytes(b'P6\n32 32\n255\n' + bytes([25, 120, 210]) * 32 * 32)
    paths = []
    for ext, codec in [('m4a', 'aac'), ('mp3', 'libmp3lame')]:
        output = tmp / ('tagged.' + ext)
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'sine=frequency=440:duration=0.2', '-i', str(cover), '-map', '0:a', '-map', '1:v',
                        '-c:a', codec, '-c:v', 'png', '-disposition:v', 'attached_pic',
                        '-metadata', 'title=Fixture Title', '-metadata', 'artist=Fixture Artist',
                        '-metadata', 'album=Fixture Album', '-metadata', 'album_artist=Fixture Album Artist',
                        '-metadata', 'composer=Fixture Composer', str(output)], check=True)
        paths.append(str(output))
    (tmp / 'check.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(tmp / 'cache'),
                    str(tmp / 'check.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), *paths], check=True)

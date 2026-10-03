#!/usr/bin/env python3
"""Headless real libavformat cover extraction on synthetic audio; never plays audio."""
from pathlib import Path
import subprocess
import sys
import tempfile

products = Path(sys.argv[1]).resolve()
ffmpeg = sys.argv[2]
repo = Path(__file__).resolve().parents[1]
frameworks = sorted(p.stem for p in products.glob('*.framework') if p.stem != 'VLCKit')
system = ['AppKit', 'AVFoundation', 'CoreAudio', 'AudioToolbox', 'CoreVideo', 'CoreMedia',
          'VideoToolbox', 'Metal', 'QuartzCore', 'OpenGL', 'IOKit', 'Security', 'SystemConfiguration', 'CoreServices', 'UniformTypeIdentifiers']
with tempfile.TemporaryDirectory(prefix='GenPlayerCover-') as folder:
    tmp = Path(folder)
    (tmp / 'cover.ppm').write_bytes(b'P6\n32 32\n255\n' + bytes([25, 120, 210]) * 32 * 32)
    def run(args):
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', *args], check=True)
    run(['-i', str(tmp / 'cover.ppm'), '-frames:v', '1', str(tmp / 'cover.png')])
    for ext, codec in [('m4a', 'aac'), ('mp3', 'libmp3lame'), ('flac', 'flac')]:
        run(['-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2', '-i', str(tmp / 'cover.png'),
             '-map', '0:a', '-map', '1:v', '-metadata', 'title=Title', '-metadata', 'artist=Artist',
             '-metadata', 'album=Album', '-metadata', 'album_artist=Album Artist', '-metadata', 'composer=Composer', '-c:a', codec, '-c:v', 'copy', '-disposition:v', 'attached_pic', str(tmp / ('audio.' + ext))])
    run(['-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2', '-c:a', 'flac',
         '-attach', str(tmp / 'cover.png'), '-metadata:s:t', 'mimetype=image/png',
         '-metadata', 'title=Title', '-metadata', 'artist=Artist', '-metadata', 'album=Album',
         '-metadata', 'album_artist=Album Artist', '-metadata', 'composer=Composer', str(tmp / 'audio.mka')])
    for ext, codec in [('ogg', 'libvorbis'), ('opus', 'libopus')]:
        run(['-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2', '-c:a', codec,
             '-metadata', 'title=Stream Title', '-metadata', 'artist=Stream Artist', '-metadata', 'album=Stream Album',
             '-metadata', 'album_artist=Stream Album Artist', '-metadata', 'composer=Stream Composer', str(tmp / ('audio.' + ext))])
    run(['-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2', '-c:a', 'libmp3lame', str(tmp / 'plain.mp3')])
    (tmp / 'bad.bin').write_bytes(b'not a media file')
    # Valid ID3 envelope with a cover larger than the accepted payload limit.
    def syncsafe(n):
        return bytes([(n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127])
    picture = b'\x00image/png\x00\x03\x00' + (tmp / 'cover.png').read_bytes() + b'\x00' * (9 * 1024 * 1024)
    frame = b'APIC' + len(picture).to_bytes(4, 'big') + b'\x00\x00' + picture
    (tmp / 'large.mp3').write_bytes(b'ID3\x03\x00\x00' + syncsafe(len(frame)) + frame + (tmp / 'plain.mp3').read_bytes())
    # Put a large skipped free box ahead of the tail metadata to require real range seeks.
    original = (tmp / 'audio.m4a').read_bytes()
    position = 0
    while original[position + 4:position + 8] != b'moov':
        position += int.from_bytes(original[position:position + 4], 'big')
    free_size = 16 * 1024 * 1024
    (tmp / 'sparse.m4a').write_bytes(original[:position] + free_size.to_bytes(4, 'big') + b'free'
                                     + b'\x00' * (free_size - 8) + original[position:])
    swift = r'''
import Foundation
actor Ranges {
    let data: Data
    var bytes = 0
    var requests = 0
    init(_ data: Data) { self.data = data }
    func read(_ offset: UInt64, _ count: Int) -> Data {
        bytes += count; requests += 1
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
    func totals() -> (Int, Int) { (bytes, requests) }
}
actor Delayed {
    var started = false
    func read(_ offset: UInt64, _ count: Int) async throws -> Data {
        started = true
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return Data(count: count)
    }
}
@main struct Check {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let expected = try Data(contentsOf: root.appendingPathComponent("cover.png"))
        for ext in ["m4a", "mp3", "flac", "mka"] {
            let cover = try await EmbeddedAudioArtworkReader.read(root.appendingPathComponent("audio." + ext))
            precondition(cover == expected, "Cover bytes differ: " + ext)
            let metadata = try await EmbeddedAudioArtworkReader.readMetadata(root.appendingPathComponent("audio." + ext))
            precondition(metadata?.isComplete == true, "Incomplete metadata: " + ext)
            for (key, value) in ["title": "Title", "artist": "Artist", "album": "Album", "albumArtist": "Album Artist", "composer": "Composer"] {
                precondition(metadata?.tags[key] == value, "Missing tag " + key + " in " + ext)
            }
            print("PASS: exact cover bytes and independent tags from " + ext)
        }
        for ext in ["ogg", "opus"] {
            let metadata = try await EmbeddedAudioArtworkReader.readMetadata(root.appendingPathComponent("audio." + ext))
            precondition(metadata?.isComplete == true && metadata?.artwork == nil, "Incomplete stream metadata: " + ext)
            for (key, value) in ["title": "Stream Title", "artist": "Stream Artist", "album": "Stream Album", "albumArtist": "Stream Album Artist", "composer": "Stream Composer"] {
                precondition(metadata?.tags[key] == value, "Missing stream tag " + key + " in " + ext)
            }
            print("PASS: stream metadata from " + ext)
        }
        for name in ["plain.mp3", "bad.bin", "large.mp3"] {
            let cover = try await EmbeddedAudioArtworkReader.read(root.appendingPathComponent(name))
            precondition(cover == nil, "Unexpected cover: " + name)
        }
        let plain = try await EmbeddedAudioArtworkReader.readMetadata(root.appendingPathComponent("plain.mp3"))
        precondition(plain?.isComplete == true && plain?.artwork == nil && plain?.tags.isEmpty == true,
                     "Absent tags must be a successful read")
        let invalid = try await EmbeddedAudioArtworkReader.readMetadata(root.appendingPathComponent("bad.bin"))
        precondition(invalid == nil, "Malformed file treated as complete metadata")
        let sparse = try Data(contentsOf: root.appendingPathComponent("sparse.m4a"))
        let ranges = Ranges(sparse)
        let rangeCover = try await EmbeddedAudioArtworkReader.read(size: UInt64(sparse.count), range: { await ranges.read($0, $1) })
        precondition(rangeCover == expected, "Range reader lost tail cover")
        let remoteMetadata = try await EmbeddedAudioArtworkReader.readMetadata(size: UInt64(sparse.count), range: {
            sparse.subdata(in: Int($0)..<Int($0) + $1)
        })
        precondition(remoteMetadata?.isComplete == true && remoteMetadata?.tags["albumArtist"] == "Album Artist")
        let (bytes, requests) = await ranges.totals()
        precondition(bytes < 1024 * 1024 && requests <= 4, "Unexpected whole-file reading")
        let oversized = try Data(contentsOf: root.appendingPathComponent("large.mp3"))
        let limited = Ranges(oversized)
        let oversizedCover = try await EmbeddedAudioArtworkReader.read(size: UInt64(oversized.count), range: { await limited.read($0, $1) })
        let (limitedBytes, limitedRequests) = await limited.totals()
        precondition(oversizedCover == nil && limitedBytes <= 8 * 1024 * 1024 && limitedRequests <= 64)
        let short = try await EmbeddedAudioArtworkReader.read(size: 1024, range: { _, _ in Data([1]) })
        precondition(short == nil, "Short response accepted")
        let delayed = Delayed()
        let inFlight = Task { try await EmbeddedAudioArtworkReader.read(size: 1024, range: { try await delayed.read($0, $1) }) }
        while !(await delayed.started) { try await Task.sleep(nanoseconds: 10_000_000) }
        inFlight.cancel()
        do { _ = try await inFlight.value; preconditionFailure("In-flight cancellation ignored") }
        catch is CancellationError {}
        print("PASS: remote tail cover with bounded ranges, short-read rejection and in-flight cancellation")
        let remote = try await EmbeddedAudioArtworkReader.read(URL(string: "https://example.invalid/audio")!)
        precondition(remote == nil)
        let cancelled = Task { try await EmbeddedAudioArtworkReader.read(root.appendingPathComponent("audio.m4a")) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError {}
        print("PASS: absent/invalid/oversized cover, remote rejection and cancellation")
    }
}
'''
    (tmp / 'check.swift').write_text(swift)
    binary = tmp / 'check'
    command = ['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(tmp / 'cache'),
               '-F', str(products), '-L', str(products), '-lMoltenVK', '-lc++', '-lz', '-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2',
               str(repo / 'GenPlayerCore/Sources/GenPlayerShell/EmbeddedAudioArtworkReader.swift'), str(tmp / 'check.swift'), '-o', str(binary)]
    for framework in frameworks + system:
        command += ['-framework', framework]
    subprocess.run(command, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', str(binary)], check=True)
    subprocess.run([str(binary), str(tmp)], check=True, timeout=30)

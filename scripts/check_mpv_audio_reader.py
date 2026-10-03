#!/usr/bin/env python3
"""Headless real libmpv test: synthetic WAV in, mono WAV out; no App, GUI or audio device."""
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import wave

products = Path(sys.argv[1]).resolve()
repo = Path(__file__).resolve().parents[1]
frameworks = sorted(p.stem for p in products.glob('*.framework') if p.stem != 'VLCKit')
assert 'Libmpv' in frameworks
system = ['AppKit', 'AVFoundation', 'CoreAudio', 'AudioToolbox', 'CoreVideo', 'CoreMedia',
          'VideoToolbox', 'Metal', 'QuartzCore', 'OpenGL', 'IOKit', 'Security', 'SystemConfiguration', 'CoreServices', 'UniformTypeIdentifiers']
with tempfile.TemporaryDirectory(prefix='GenPlayerMPVAudio-') as temporary:
    folder = Path(temporary)
    with wave.open(str(folder / 'input.wav'), 'wb') as source:
        source.setnchannels(2)
        source.setsampwidth(2)
        source.setframerate(8000)
        source.writeframes(b''.join(struct.pack('<hh', int(8000 * math.sin(2 * math.pi * 440 * n / 8000)),
                                               int(8000 * math.sin(2 * math.pi * 440 * n / 8000))) for n in range(16000)))
    # Minimal Matroska with non-contiguous container track numbers and distinct
    # tones/origins; no downloaded media or external encoder is needed.
    def vint(value):
        width = next(n for n in range(1, 9) if value < (1 << (7 * n)) - 1)
        return ((1 << (7 * width)) | value).to_bytes(width, 'big')
    def element(tag, payload):
        return tag.to_bytes((tag.bit_length() + 7) // 8, 'big') + vint(len(payload)) + payload
    def number(tag, value):
        return element(tag, value.to_bytes(max(1, (value.bit_length() + 7) // 8), 'big'))
    header = element(0x1A45DFA3, number(0x4286, 1) + number(0x42F7, 1) + number(0x42F2, 4)
                     + number(0x42F3, 8) + element(0x4282, b'matroska') + number(0x4287, 4) + number(0x4285, 2))
    info = element(0x1549A966, number(0x2AD7B1, 1000000) + element(0x4489, struct.pack('>d', 3500))
                   + element(0x4D80, b'GenPlayer test') + element(0x5741, b'GenPlayer test'))
    tracks = []
    packets = []
    for track, origin, frequency, language in [(2, 1000, 440, b'eng'), (5, 1500, 880, b'jpn')]:
        audio = element(0xE1, element(0xB5, struct.pack('>d', 16000)) + number(0x9F, 1) + number(0x6264, 16))
        tracks.append(element(0xAE, number(0xD7, track) + number(0x73C5, track) + number(0x83, 2)
                              + element(0x86, b'A_PCM/INT/LIT') + element(0x22B59C, language) + audio))
        for index in range(100):
            pcm = b''.join(struct.pack('<h', int(8000 * math.sin(2 * math.pi * frequency * n / 16000)))
                           for n in range(index * 320, (index + 1) * 320))
            timestamp = origin + index * 20
            packets.append((timestamp, element(0xA3, vint(track) + struct.pack('>hB', timestamp, 0x80) + pcm)))
    cluster = element(0x1F43B675, number(0xE7, 0) + b''.join(packet for _, packet in sorted(packets)))
    (folder / 'multi.mkv').write_bytes(header + element(0x18538067, info + element(0x1654AE6B, b''.join(tracks)) + cluster))
    binary = folder / 'check'
    command = ['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'cache'),
               '-F', str(products), '-L', str(products), '-lMoltenVK', '-lc++', '-lz', '-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2',
               str(repo / 'GenPlayerCore/Sources/GenPlayerShell/MPVStartupOptionPolicy.swift'),
               str(repo / 'GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift'),
               str(repo / 'GenPlayerCore/Sources/GenPlayerShell/MPVAudioFileReader.swift'),
               str(repo / 'GenPlayerCore/Sources/GenPlayerShell/MacMatroskaAudioOrigin.swift'),
               str(repo / 'scripts/check_mpv_audio_reader.swift'), '-o', str(binary)]
    for framework in frameworks + system:
        command += ['-framework', framework]
    subprocess.run(command, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', str(binary)], check=True)
    subprocess.run([str(binary), str(folder)], check=True, timeout=30)
    subprocess.run([str(binary), str(folder)], check=True, timeout=10,
                   env={**os.environ, 'GENPLAYER_DISABLED_ENGINES': 'mpv'})
    def read_pcm(path):
        data = path.read_bytes()
        assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
        chunks = {}
        offset = 12
        while offset + 8 <= len(data):
            length = struct.unpack_from('<I', data, offset + 4)[0]
            chunks[data[offset:offset + 4]] = data[offset + 8:offset + 8 + length]
            offset += 8 + length + length % 2
        fmt, pcm = chunks[b'fmt '], chunks[b'data']
        encoding, channels, rate, _, alignment, bits = struct.unpack_from('<HHIIHH', fmt)
        assert encoding in (1, 65534) and channels == 1 and bits == 16 and rate == 16000 and alignment == 2
        if encoding == 65534:
            assert fmt[24:40] == bytes.fromhex('0100000000001000800000aa00389b71')
        assert abs(len(pcm) / 2 / rate - 2) < 0.05, (path.name, len(pcm) / 2 / rate)
        samples = struct.unpack('<' + 'h' * (len(pcm) // 2), pcm)
        assert 3000 < math.sqrt(sum(value * value for value in samples) / len(samples)) < 12000
        return samples
    read_pcm(folder / "output.wav")
    for index, frequency in enumerate([440, 880]):
        samples = read_pcm(folder / f"track-{index}.wav")
        def strength(hz):
            return abs(sum(value * math.sin(2 * math.pi * hz * n / 16000) for n, value in enumerate(samples)))
        assert strength(frequency) > 10 * max(1, strength(1320 - frequency)), "Wrong audio track decoded"
    print('PASS: output sample rate, channels, bit depth, duration and non-silent amplitude')

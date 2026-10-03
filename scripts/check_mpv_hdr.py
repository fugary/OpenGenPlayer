#!/usr/bin/env python3
"""Synthetic HDR offscreen buffers only: no application, display, audio or screenshots."""
import pathlib, subprocess, sys, tempfile, struct
products = pathlib.Path(sys.argv[1]).resolve()
ffmpeg = sys.argv[2]
repo = pathlib.Path(__file__).resolve().parents[1]
sources = repo / 'GenPlayerCore/Sources/GenPlayerShell'
with tempfile.TemporaryDirectory(prefix='GenPlayerHDR-') as temporary:
    folder = pathlib.Path(temporary)
    renderer = folder / 'MPVSampleBufferRenderer.swift'
    renderer.write_text((sources / renderer.name).read_text().replace('#if os(iOS) || os(tvOS)', '#if os(macOS)'))
    frameworks = [p.stem for p in products.glob('*.framework') if p.stem != 'VLCKit']
    frameworks += ['AppKit','AVFoundation','CoreAudio','AudioToolbox','CoreVideo','CoreMedia','VideoToolbox','Metal','QuartzCore','OpenGL','IOKit','Security','SystemConfiguration','CoreServices','UniformTypeIdentifiers']
    command = ['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',str(folder / 'cache'),'-F',str(products),'-L',str(products),'-lMoltenVK','-lc++','-lz','-lbz2','-liconv','-lexpat','-lresolv','-lxml2']
    for name in ['PlaybackFrameDelivery.swift','MPVPixelBufferOutput.swift','MPVStartupOptionPolicy.swift','MPVHDRToneMapper.swift']:
        command += [str(sources / name)]
    command += [str(renderer), str(repo / 'scripts/check_mpv_hdr.swift'), '-o', str(folder / 'check')]
    for name in frameworks: command += ['-framework',name]
    subprocess.run(command,check=True)
    subprocess.run(['codesign','--force','--sign','-',str(folder / 'check')],check=True)
    for transfer, tag, bars in [('pq','smpte2084',[0,.508078,.751827,1]),('hlg','arib-std-b67',[0,.5,.75,1])]:
        raw = b''.join(struct.pack('<HHH', *([round(bars[x//32]*65535)]*3)) for y in range(32) for x in range(128))
        (folder / 'in.rgb').write_bytes(raw)
        for pixel_format, matrix in [('gbrp16le', 'rgb'), ('yuv420p10le', 'bt2020nc')]:
            movie = folder / (transfer + '-' + pixel_format + '.mkv')
            subprocess.run([ffmpeg,'-v','error','-f','rawvideo','-pixel_format','rgb48le','-video_size','128x32','-i',str(folder/'in.rgb'),'-frames:v','1','-c:v','ffv1','-pix_fmt',pixel_format,'-color_primaries','bt2020','-color_trc',tag,'-colorspace',matrix,str(movie)],check=True)
            subprocess.run([str(folder/'check'),str(movie),transfer + '/' + pixel_format],check=True,timeout=20)

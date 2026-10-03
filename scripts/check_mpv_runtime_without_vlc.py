#!/usr/bin/env python3
"""Type-check the production mpv runtime with no VLC module or replacement types.
Usage: check_mpv_runtime_without_vlc.py <Build/Products/Debug[-platform]> [sdk] [target]
This verifies the decoder/render/preview/audio-reader boundary, not the app shell.
"""
from pathlib import Path
import subprocess, sys, tempfile
products = Path(sys.argv[1]).resolve()
sdk = sys.argv[2] if len(sys.argv) > 2 else 'macosx'
target = sys.argv[3] if len(sys.argv) > 3 else 'arm64-apple-macos12.0'
repo = Path(__file__).resolve().parents[1]
source = repo / 'GenPlayerCore/Sources/GenPlayerShell'
sources = ['MacMPVEngine', 'MacMPVStream', 'MacMPVTrack', 'MacMPVCaptureFrame',
           'MPVStartupOptionPolicy', 'MPVSoftwareRenderSize', 'MPVSimulatorRenderer',
           'MPVVideoSurfaceView', 'PlaybackTransportState', 'PlaybackFrameDelivery',
           'PlaybackEngineCapabilities', 'PlaybackTransport', 'MPVPlaybackTransport',
           'MPVPixelBufferOutput', 'MPVSampleBufferRenderer', 'MPVHDRToneMapper',
           'PlaybackPreviewProvider', 'MPVPlaybackPreviewProvider',
           'EmbeddedAudioArtworkReader', 'MPVAudioFileReader']
with tempfile.TemporaryDirectory(prefix='GenPlayerRuntimeNoVLC-') as work:
    root = Path(work)
    frameworks = root / 'frameworks'; frameworks.mkdir()
    for framework in products.glob('*.framework'):
        if 'vlc' not in framework.name.lower():
            (frameworks/framework.name).symlink_to(framework)
    bridge = root/'GenPlayerMPVBridge'; bridge.mkdir()
    headers = repo/'GenPlayerCore/Sources/GenPlayerMPVBridge/include'
    (bridge/'module.modulemap').write_text('module GenPlayerMPVBridge { umbrella "' + str(headers) + '" export * }\n')
    sentinel = root/'NoVLC.swift'
    sentinel.write_text(''.join('#if canImport(' + name + ')\n#error("VLC is visible in the mpv runtime")\n#endif\n'
        for name in ['VLCKitSPM','VLCKit','MobileVLCKit','TVVLCKit','GenPlayerVLCBridge']))
    sdk_path = subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
    command = ['xcrun','swiftc','-typecheck','-parse-as-library','-module-name','GenPlayerMPVIndependent',
        '-swift-version','5','-sdk',sdk_path,'-target',target,'-module-cache-path',str(root/'cache'),
        '-I',str(root),'-F',str(frameworks),str(sentinel)]
    command += [str(source/(name+'.swift')) for name in sources]
    subprocess.run(command,check=True)
    print('PASS:',len(sources),'production mpv runtime files compile without VLC:',target)

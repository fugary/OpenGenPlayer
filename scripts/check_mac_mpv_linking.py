#!/usr/bin/env python3
"""Inspect the built Apple Mach-O without loading or launching the app.

Usage: python3 scripts/check_mac_mpv_linking.py <Gen Player.app>
Checks Debug's debug dylib or Release's executable. MPVKit dependencies must not
bind to VLCKit's exported copies. Intentional VLC playback APIs remain; SFTP must resolve locally.
"""
from pathlib import Path
import re
import plistlib
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    app = Path(sys.argv[1])
    contents = app / 'Contents'
    folder = contents / 'MacOS' if contents.exists() else app
    info = contents / 'Info.plist' if contents.exists() else app / 'Info.plist'
    executable = plistlib.loads(info.read_bytes())['CFBundleExecutable']
    binary = folder / (executable + '.debug.dylib')
    if not binary.exists():
        binary = folder / executable
    imports = subprocess.check_output(['xcrun', 'dyld_info', '-imports', str(binary)], text=True)
    vlc = re.findall(r' (_\S+)\s+\(from (?:Mobile|TV)?VLCKit\)', imports)
    unexpected = [symbol for symbol in vlc if not symbol.startswith((
        '_VLC', '_OBJC_CLASS_$_VLC', '_OBJC_METACLASS_$_VLC', '_libvlc_'))]
    definitions = subprocess.check_output(['nm', '-gU', str(binary)], text=True)
    for symbol in ('_mpv_create', '_avcodec_version', '_avformat_version',
                   '_avutil_version', '_avformat_open_input', '_avio_alloc_context', '_ass_library_init', '_FT_Init_FreeType',
                   '_GPMPVMetalContextRevision', '_GPMPVASSRendererRevision', '_GPMPVTransformSecondaryASS', '_GPMPVSetSecondaryASS', '_GPMPVSetSecondaryASSMirror', '_GPSSH2Initialize', '_libssh2_session_handshake',
                   '_libssh2_sftp_open_ex', '_libssh2_sftp_read', '_libssh2_sftp_seek64'):
        if not re.search(r'\bT ' + re.escape(symbol) + r'$', definitions, re.MULTILINE):
            raise SystemExit(f'Missing local MPVKit definition: {symbol}')
    if not re.search(r'\b[SD] _ra_ctx_vulkan_moltenvk$', definitions, re.MULTILINE):
        raise SystemExit('Missing local Metal context descriptor')
    if not re.search(r'\b[SD] _sd_ass$', definitions, re.MULTILINE):
        raise SystemExit('Missing local ASS renderer descriptor')
    if '_OBJC_CLASS_$_GPMPVMetalLayer' not in definitions:
        raise SystemExit('Missing Metal resize layer')
    if unexpected:
        raise SystemExit('MPVKit dependency symbols incorrectly imported from VLC:\n' + '\n'.join(unexpected))
    if not vlc:
        raise SystemExit('VLC fallback is not linked; this is not a coexistence check.')
    print(f'PASS: MPVKit dependency bindings and Metal resize adapter are local; {len(vlc)} intentional VLC imports remain')
    print('PASS: pinned ASS renderer and per-player geometry bridge are linked locally')
    print('PASS: SFTP libssh2 calls bind locally, with no libssh2 imports from VLCKit')


if __name__ == '__main__':
    main()

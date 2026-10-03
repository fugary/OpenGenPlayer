#!/usr/bin/env python3
"""Check real libmpv initialization under Hardened Runtime, with no JIT exceptions.

Usage: python3 scripts/check_mac_mpv_startup.py <macOS Build/Products/Debug> [--with-vlc]
Requires a completed macOS build. Runs a temporary command-line helper with null
video/audio outputs. Never launches GenPlayer, creates a window, or opens media.
The default checks Hardened Runtime without JIT exceptions. --with-vlc checks
coexistence and the project's link order, using an ad-hoc CLI without Hardened
Runtime because the development-signed VLC binary has a different signing identity.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--with-vlc'):
        raise SystemExit(__doc__)
    with_vlc = len(sys.argv) == 3
    products = Path(sys.argv[1]).resolve()
    repo = Path(__file__).resolve().parents[1]
    source = (repo / 'GenPlayerCore/Sources/GenPlayerShell/MacMPVEngine.swift').read_text()
    block = source.split('let options = [', 1)[1].split('].merging', 1)[0]
    options = dict(re.findall(r'"([a-z-]+)": "([^"]+)"', block))
    # Exercise production initialization settings without graphics/audio devices.
    options.update({'vo': 'null', 'ao': 'null', 'force-window': 'no'})
    # Surface fatal version checks before mpv can call exit(1).
    if with_vlc:
        options.update({'terminal': 'yes', 'msg-level': 'all=error'})
    frameworks = sorted(p.stem for p in products.glob('*.framework') if p.stem != 'VLCKit')
    if 'Libmpv' not in frameworks or not (products / 'libMoltenVK.a').exists():
        raise SystemExit('Build macOS first; libmpv or MoltenVK is missing from the products directory.')
    system_frameworks = ['AppKit', 'AVFoundation', 'CoreAudio', 'AudioToolbox', 'CoreVideo',
                         'CoreFoundation', 'CoreMedia', 'Metal', 'VideoToolbox', 'QuartzCore',
                         'OpenGL', 'IOKit', 'Security', 'CoreServices']
    checks = '\n'.join(
        f'if (mpv_set_option_string(h, {json.dumps(k)}, {json.dumps(v)}) < 0) return 3;'
        for k, v in options.items())
    program = '''#include <mpv/client.h>
#include <stdio.h>
int main(void) {
    setbuf(stdout, NULL);
    for (int cycle = 0; cycle < 3; cycle++) {
        mpv_handle *h = mpv_create();
        if (!h) return 2;
''' + checks + '''
        puts("Initializing libmpv with null outputs and no media");
        int result = mpv_initialize(h);
        if (result < 0) { mpv_destroy(h); return 4; }
        for (int event = 0; event < 10; event++) mpv_wait_event(h, 0.1);
        mpv_terminate_destroy(h);
    }
    puts("PASS: three initialization/shutdown cycles");
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix='GenPlayerMPVStartup-') as temp:
        folder = Path(temp)
        code, binary = folder / 'check.c', folder / 'check'
        code.write_text(program)
        clang = Path(subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip())
        swift_libraries = clang.parent.parent / 'lib/swift/macosx'
        command = [str(clang), str(code), '-F', str(products), '-I', str(products / 'Libmpv.framework/Headers'),
                   '-o', str(binary), '-L', str(products), '-lMoltenVK', '-L', str(swift_libraries)]
        # Match the app's early system libraries, then its explicit framework priority.
        command += ['-lc++', '-lz', '-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2']
        if with_vlc:
            project = json.loads(subprocess.check_output([
                'plutil', '-convert', 'json', '-o', '-',
                str(repo / 'GenPlayer.xcodeproj/project.pbxproj')], text=True))
            configs = [item['buildSettings'].get('OTHER_LDFLAGS', [])
                       for item in project['objects'].values()
                       if item.get('isa') == 'XCBuildConfiguration'
                       and item.get('buildSettings', {}).get('INFOPLIST_FILE') == 'GenPlayer_macOS/Info.plist']
            if len(configs) != 2 or configs[0] != configs[1]:
                raise SystemExit('macOS Debug/Release linker settings must agree.')
            command += [arg for arg in configs[0] if arg != '$(inherited)']
            command += ['-framework', 'VLCKit']
        for framework in frameworks + system_frameworks:
            command += ['-framework', framework]
        subprocess.run(command, check=True)
        if with_vlc:
            subprocess.run(['install_name_tool', '-change',
                            '@loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit',
                            str(products / 'VLCKit.framework/Versions/A/VLCKit'), str(binary)], check=True)
        signing = [] if with_vlc else ['--options', 'runtime']
        subprocess.run(['codesign', '--force', '--sign', '-'] + signing + [str(binary)], check=True)
        print('Checking VLC coexistence' if with_vlc else 'Checking Hardened Runtime without JIT entitlements', flush=True)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build official libssh2 in isolation; no app, socket, credentials or remote server.
Usage: check_standalone_ssh2.py <libssh2-1.11.1.tar.gz> <macOS products directory>
The archive is obtained separately from https://libssh2.org/download/.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

archive = Path(sys.argv[1]).resolve()
products = Path(sys.argv[2]).resolve()
expected = 'd9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected, 'Unexpected source archive'
with tempfile.TemporaryDirectory(prefix='GenPlayerSSH2-') as folder:
    work = Path(folder)
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts
            assert not member.issym() and not member.islnk()
        source.extractall(work)
    root = work / 'libssh2-1.11.1'
    files = re.findall(r'\b[\w-]+\.c\b', (root / 'src/Makefile.inc').read_text().split('HHEADERS')[0])
    vendored = Path(__file__).resolve().parents[1] / 'GenPlayerCore/Sources/GenPlayerSSH2'
    manifest = json.loads((vendored / 'vendor-sha256.json').read_text())
    for relative, digest in manifest.items():
        content = (vendored / relative).read_bytes()
        assert hashlib.sha256(content).hexdigest() == digest, relative
        assert content == (root / Path(relative).relative_to('vendor')).read_bytes(), relative
    root = vendored / 'vendor'
    include = ['-I', str(vendored / 'config'), '-I', str(root / 'src'), '-I', str(root / 'include'),
               '-I', str(vendored / 'include'), '-I', str(products / 'Libcrypto.framework/Headers')]
    files.append('SSH2Bridge.c')
    definitions = ['-DHAVE_CONFIG_H', '-DLIBSSH2_OPENSSL', '-DLIBSSH2_HAVE_ZLIB', '-DLIBSSH2_DSA_ENABLE',
                   '-D__STDC_WANT_LIB_EXT1__=1', '-Wno-deprecated-declarations', '-O1']
    libraries = {}
    for sdk, target in [('macosx', 'arm64-apple-macos12'), ('iphonesimulator', 'arm64-apple-ios15-simulator'),
                        ('iphoneos', 'arm64-apple-ios15'), ('appletvsimulator', 'arm64-apple-tvos16-simulator'),
                        ('appletvos', 'arm64-apple-tvos16'), ('macosx', 'x86_64-apple-macos12'),
                        ('iphonesimulator', 'x86_64-apple-ios15-simulator'), ('appletvsimulator', 'x86_64-apple-tvos16-simulator')]:
        build = work / target
        build.mkdir()
        sysroot = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        def compile_file(name):
            output = build / (name + '.o')
            source = vendored / name if name == 'SSH2Bridge.c' else root / 'src' / name
            result = subprocess.run(['xcrun', 'clang', '-target', target, '-isysroot', sysroot, *include,
                                     *definitions, '-c', str(source), '-o', str(output)], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stderr)
            return output
        with ThreadPoolExecutor(max_workers=4) as pool:
            objects = list(pool.map(compile_file, files))
        library = build / 'libssh2.a'
        subprocess.run(['xcrun', 'libtool', '-static', '-o', str(library), *map(str, objects)], check=True)
        if target.startswith('arm64'): libraries[sdk] = library
        print('PASS: standalone libssh2 source compile', target, flush=True)
    probe = work / 'probe.c'
    probe.write_text(r'''
#include <stddef.h>
#include <stdio.h>
#include <assert.h>
#include "libssh2.h"
#include "libssh2_sftp.h"
_Static_assert(sizeof(LIBSSH2_SFTP_ATTRIBUTES) == 56, "Swift SFTP attribute layout");
_Static_assert(offsetof(LIBSSH2_SFTP_ATTRIBUTES, filesize) == 8, "Swift size offset");
_Static_assert(offsetof(LIBSSH2_SFTP_ATTRIBUTES, mtime) == 48, "Swift timestamp offset");
int main(void) {
    assert(libssh2_init(0) == 0);
    LIBSSH2_SESSION *session = libssh2_session_init();
    assert(session);
    libssh2_session_set_timeout(session, 15000);
    assert(libssh2_session_get_timeout(session) == 15000);
#ifdef GP_VLC_BASELINE
    puts("version unavailable (VLCKit does not export libssh2_version)");
#else
    printf("version %s\n", libssh2_version(0));
#endif
    for(int method = 0; method < 8; ++method) {
        const char **algorithms = NULL;
        int count = libssh2_session_supported_algs(session, method, &algorithms);
        assert(count > 0);
        for(int index = 0; index < count; ++index) printf("%d %s\n", method, algorithms[index]);
        libssh2_free(session, (void *)algorithms);
    }
    assert(libssh2_session_free(session) == 0);
    libssh2_exit();
    return 0;
}
''')
    result = {}
    for name, flags in [('independent', [str(libraries['macosx']), '-framework', 'Libcrypto', '-lz', '-framework', 'Security']),
                        ('vlc', ['-DGP_VLC_BASELINE', '-framework', 'VLCKit', '-Wl,-rpath,' + str(products)])]:
        binary = work / name
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-I', str(root / 'include'), '-F', str(products),
                        str(probe), *flags, '-o', str(binary)], check=True)
        output = subprocess.check_output([str(binary)], text=True, env=dict(os.environ, DYLD_FRAMEWORK_PATH=str(products)), timeout=10)
        imports = subprocess.check_output(['xcrun', 'dyld_info', '-imports', str(binary)], text=True)
        if name == 'independent':
            assert 'VLCKit' not in imports
        lines = output.splitlines()
        print(name, lines[0], flush=True)
        result[name] = set(lines[1:])
    missing = result['vlc'] - result['independent']
    added = result['independent'] - result['vlc']
    print('Algorithms missing from standalone candidate:', sorted(missing), flush=True)
    print('Algorithms added by standalone candidate:', sorted(added), flush=True)
    assert not missing, 'Do not migrate until algorithm differences are resolved'
    print('PASS: offline initialization, SFTP ABI, timeout, algorithm inventory; no VLCKit in candidate')
    (work / 'module.modulemap').write_text(
        'module GenPlayerSSH2 { header "' + str(vendored / 'include/GenPlayerSSH2.h') + '" export * }\n')
    swift = work / 'abi.swift'
    swift.write_text(r'''
import GenPlayerSSH2
precondition(GPSSH2Initialize() == 0)
precondition(String(cString: GPSSH2Version()) == "1.11.1")
precondition(MemoryLayout<LIBSSH2_SFTP_ATTRIBUTES>.size == 56)
let session = libssh2_session_init_ex(nil, nil, nil, nil)!
// C long is 64-bit on every supported Apple architecture.
let timeout = Int(Int32.max) + 42
libssh2_session_set_timeout(session, timeout)
precondition(libssh2_session_get_timeout(session) == timeout)
let failure: Int32 = libssh2_session_handshake(session, -1)
precondition(failure < 0)
precondition(libssh2_session_free(session) == 0)
print("PASS: actual Swift/C imports, 64-bit timeout and signed handshake failure; no socket opened")
''')
    swift_binary = work / 'swift-abi'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'cache'), '-I', str(work),
                    '-F', str(products), str(swift), str(libraries['macosx']), '-framework', 'Libcrypto',
                    '-lz', '-framework', 'Security', '-o', str(swift_binary)], check=True)
    subprocess.run([str(swift_binary)], check=True, timeout=10)

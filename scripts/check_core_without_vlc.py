#!/usr/bin/env python3
"""Type-check the complete production Core module with VLC modules unavailable.

Usage: check_core_without_vlc.py <successful xcodebuild log>
Uses the SDK, architecture and non-VLC dependency modules of that build. Does not
link or launch an app, and does not replace production types with test doubles.
"""
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    lines = Path(sys.argv[1]).read_text().splitlines()
    candidates = [line.split(' -- ', 1)[1] for line in lines
                  if 'builtin-SwiftDriver -- ' in line
                  and '-module-name GenPlayerCore ' in line and '-target arm64-' in line]
    if not candidates or '** BUILD SUCCEEDED **' not in lines:
        raise SystemExit('A successful arm64 build with the Core compiler invocation is required.')
    args = shlex.split(candidates[-1])
    def value(flag):
        return args[args.index(flag) + 1]
    products = Path(value('-I'))
    filelist = next(Path(arg[1:]) for arg in args if arg.startswith('@'))
    sources = [part for line in filelist.read_text().splitlines() for part in shlex.split(line)]
    if not sources or any('VLCKit' in name for name in sources):
        raise SystemExit('Unexpected Core source list.')
    with tempfile.TemporaryDirectory(prefix='GenPlayerCoreNoVLC-') as directory:
        temp = Path(directory)
        modules = temp / 'modules'
        frameworks = temp / 'frameworks'
        modules.mkdir()
        frameworks.mkdir()
        for item in products.glob('*.framework'):
            if 'VLC' not in item.name:
                (frameworks / item.name).symlink_to(item)
        sentinel = temp / 'NoVLC.swift'
        sentinel.write_text(''.join(f'#if canImport({name})\n#error("{name} leaked into the isolated Core build")\n#endif\n'
                                    for name in ('VLCKitSPM', 'VLCKit', 'MobileVLCKit', 'TVVLCKit', 'GenPlayerVLCBridge')))
        command = [args[0], '-typecheck', '-parse-as-library', '-module-name', 'GenPlayerCore',
                   '-sdk', value('-sdk'), '-target', value('-target'), '-swift-version', '5',
                   '-module-cache-path', str(temp / 'cache'), '-I', str(modules), '-F', str(frameworks),
                   '-DSWIFT_PACKAGE', '-DDEBUG', '-DSWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE']
        for index, arg in enumerate(args[:-1]):
            if arg == '-Xcc':
                setting = args[index + 1]
                if setting.startswith(('-fmodule-map-file=', '-I', '-D')):
                    if 'VLC' in setting:
                        raise SystemExit('Core compiler command still depends on VLC: ' + setting)
                    command += ['-Xcc', setting]
        # Debug Swift modules embed their original search paths, which would make
        # VLC visible again. Rebuild the three real Swift dependencies in isolation.
        repo = Path(__file__).resolve().parents[1]
        checkouts = products.parents[2] / 'SourcePackages/checkouts'
        dependencies = [('FilesProvider', repo / 'FileProvider/Sources'),
                        ('AMSMB2', checkouts / 'AMSMB2/AMSMB2'),
                        ('NFSKit', checkouts / 'NFSKit/Sources/NFSKit')]
        for name, source_root in dependencies:
            dependency_sources = sorted(source_root.rglob('*.swift'))
            if not dependency_sources:
                raise SystemExit('Missing dependency sources: ' + str(source_root))
            dependency_command = list(command)
            dependency_command[dependency_command.index('-typecheck')] = '-emit-module'
            dependency_command[dependency_command.index('-module-name') + 1] = name
            dependency_command += ['-emit-module-path', str(modules / (name + '.swiftmodule'))]
            dependency_command += [str(path) for path in dependency_sources] + [str(sentinel)]
            result = subprocess.run(dependency_command)
            if result.returncode:
                raise SystemExit(result.returncode)
        command += sources + [str(sentinel)]
        result = subprocess.run(command)
        if result.returncode:
            raise SystemExit(result.returncode)
        print(f'PASS: {len(sources)} production Core sources type-check without VLC ({value("-target")})')


if __name__ == '__main__':
    main()

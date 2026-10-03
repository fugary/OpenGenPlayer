#!/usr/bin/env python3
"""Build the iOS VLC rate fix; retain the original macOS/tvOS binaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "VLCKitPatched"
PATCH = PACKAGE / "patches/0001-continuous-rate.patch"
KIT_REV = "319ed2c0724e3d4c4d34889a62fef1ae269491bc"
VLC_REV = "79128878ddb2c280bbb6c89c76a46b31a80ade1c"
BASE_URL = "https://github.com/fugary/vlckit-spm/releases/download/3.7.3/VLCKit-all.xcframework.zip"
BASE_SHA = "d596bd66a3bce763c4806875d470af8c26f54275f5661d65c64bfe9324eff131"


def run(*args, cwd=None, **kwargs):
    subprocess.run(args, cwd=cwd, check=True, **kwargs)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def fetch_checkout(url, revision, path):
    path.mkdir(parents=True)
    run("git", "init", str(path))
    run("git", "fetch", "--depth", "1", url, revision, cwd=path)
    run("git", "checkout", "--detach", "FETCH_HEAD", cwd=path)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path).decode().strip()
    if actual != revision:
        raise RuntimeError(f"Unexpected source revision in {path}")


def prepare(work, identity):
    marker = work / ".genplayer-rate-source.json"
    if marker.exists():
        if json.loads(marker.read_text()) != identity:
            raise RuntimeError("Source/patch changed; choose a new empty --work-dir.")
        run("git", "apply", "--reverse", "--check", str(PATCH), cwd=work / "libvlc/vlc")
        return
    if work.exists() and any(work.iterdir()):
        raise RuntimeError("Refusing to overwrite an unmarked nonempty build directory.")
    # git init requires an empty directory, including on interrupted first runs.
    if work.exists():
        work.rmdir()
    fetch_checkout("https://github.com/videolan/vlckit.git", KIT_REV, work)
    source = work / "libvlc/vlc"
    fetch_checkout("https://github.com/videolan/vlc.git", VLC_REV, source)
    for patch in sorted((work / "libvlc/patches").glob("*.patch")):
        run("git", "apply", "--whitespace=nowarn", str(patch), cwd=source)
    run("git", "apply", str(PATCH), cwd=source)

    # Build support only: iOS 15 minimum, unsigned frameworks, macOS checksum
    # utility compatibility, and HTTPS for the upstream download mirrors.
    builder = work / "buildMobileVLCKit.sh"
    text = builder.read_text().replace("SDK_MIN=9.0", "SDK_MIN=15.0")
    text = text.replace("               SKIP_INSTALL=no \\",
                        "               CODE_SIGNING_ALLOWED=NO \\\n               SKIP_INSTALL=no \\")
    builder.write_text(text)
    for relative in ("extras/tools/tools.mak", "extras/tools/packages.mak", "contrib/src/main.mak"):
        path = source / relative
        text = path.read_text().replace("SHA512SUM = sha512sum --check", "SHA512SUM = shasum -a 512 --check")
        text = text.replace("SHA512SUM = sha512sum -c", "SHA512SUM = shasum -a 512 -c")
        for host in ("downloads.videolan.org", "download.videolan.org", "ftp.gnu.org"):
            text = text.replace("http://" + host, "https://" + host)
        path.write_text(text)
    marker.write_text(json.dumps(identity, indent=2) + "\n")


def assemble(base, patched, identity):
    original_info = plistlib.loads((base / "Info.plist").read_bytes())
    patched_info = plistlib.loads((patched / "Info.plist").read_bytes())
    ios = patched_info["AvailableLibraries"]
    variants = {(lib.get("SupportedPlatformVariant", "device"), tuple(sorted(lib["SupportedArchitectures"]))) for lib in ios}
    if any(lib["SupportedPlatform"] != "ios" for lib in ios) or variants != {
        ("device", ("arm64",)), ("simulator", ("arm64", "x86_64"))
    }:
        raise RuntimeError("The patched framework must contain iOS arm64 and both simulator architectures.")
    others = [lib for lib in original_info["AvailableLibraries"] if lib["SupportedPlatform"] != "ios"]
    if {lib["SupportedPlatform"] for lib in others} != {"macos", "tvos"}:
        raise RuntimeError("The base framework must be the complete VLCKit 3.7.3 distribution.")
    artifacts = PACKAGE / "Artifacts"
    output = artifacts / "VLCKit-all.xcframework"
    stamp = artifacts / "build.json"
    if output.exists():
        if output.is_symlink() or not stamp.exists():
            raise RuntimeError("Refusing to replace an unmarked framework.")
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for origin, libraries in ((base, others), (patched, ios)):
        for lib in libraries:
            identifier = lib["LibraryIdentifier"]
            shutil.copytree(origin / identifier, output / identifier, symlinks=True)
    original_info["AvailableLibraries"] = others + ios
    (output / "Info.plist").write_bytes(plistlib.dumps(original_info))
    stamp.write_text(json.dumps(identity, indent=2) + "\n")
    print(f"Ready: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=PACKAGE / ".build/vlckit-rate")
    parser.add_argument("--base-xcframework", type=Path, help="Optional existing, unmodified VLCKit 3.7.3 artifact")
    parser.add_argument("--assemble-only", action="store_true", help="Reuse a completed build with a matching stamp")
    parser.add_argument("--ensure", action="store_true", help="Skip rebuilding when the current artifact matches this patch")
    args = parser.parse_args()
    work = args.work_dir.resolve()
    identity = {"vlckit": KIT_REV, "vlc": VLC_REV, "patch_sha256": digest(PATCH)}
    artifact_stamp = PACKAGE / "Artifacts/build.json"
    artifact_info = PACKAGE / "Artifacts/VLCKit-all.xcframework/Info.plist"
    if args.ensure and artifact_stamp.exists() and artifact_info.exists():
        if json.loads(artifact_stamp.read_text()) == identity:
            info = plistlib.loads(artifact_info.read_bytes())
            if all((artifact_info.parent / lib["LibraryIdentifier"] / lib["LibraryPath"]).is_dir()
                   for lib in info["AvailableLibraries"]):
                print("Patched VLC artifact is current.")
                return
    prepare(work, identity)
    build_stamp = work / ".genplayer-rate-build.json"
    if args.assemble_only:
        if not build_stamp.exists() or json.loads(build_stamp.read_text()) != identity:
            raise RuntimeError("No completed build of this exact patch was recorded.")
    else:
        # This builds only. It never installs/launches an app or simulator.
        env = dict(os.environ, MAKE_JOBS=os.environ.get("MAKE_JOBS", "10"), MAKEINFO="true")
        tool_dir = work / "libvlc/vlc/extras/tools"
        env["PATH"] = str(tool_dir / "build/bin") + os.pathsep + env["PATH"]
        run("./bootstrap", cwd=tool_dir, env=env)
        run("make", "all", ".buildgas", "MAKEINFO=true", cwd=tool_dir, env=env)
        run("./buildMobileVLCKit.sh", "-n", "-f", "-v", cwd=work, env=env)
        build_stamp.write_text(json.dumps(identity, indent=2) + "\n")
    base = args.base_xcframework
    if base is None:
        archive = work / "VLCKit-3.7.3.zip"
        if not archive.exists():
            run("curl", "--fail", "--location", "--retry", "3", "--output", str(archive), BASE_URL)
        if digest(archive) != BASE_SHA:
            raise RuntimeError("Original VLCKit archive checksum mismatch.")
        unpacked = work / "original-vlckit"
        unpacked.mkdir(exist_ok=True)
        run("ditto", "-x", "-k", str(archive), str(unpacked))
        base = unpacked / "VLCKit-all.xcframework"
    assemble(base.resolve(), work / "build/MobileVLCKit.xcframework", identity)


if __name__ == "__main__":
    main()

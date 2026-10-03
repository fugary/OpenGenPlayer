// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GenPlayerCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v16)
    ],
    products: [
        .library(
            name: "GenPlayerCore",
            targets: ["GenPlayerCore"]),
        .library(
            name: "GenPlayerShell",
            targets: ["GenPlayerShell"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2", from: "4.0.3"),
        .package(name: "FileProvider", path: "../FileProvider"),
        .package(url: "https://github.com/alexiscn/NFSKit.git", branch: "main"),
        .package(path: "../VLCKitPatched"),
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "GenPlayerCore",
            dependencies: [
                "GenPlayerSSH2",
                .product(name: "AMSMB2", package: "AMSMB2"),
                .product(name: "FilesProvider", package: "FileProvider"),
                .product(name: "NFSKit", package: "NFSKit"),
            ]),
        .target(
            name: "GenPlayerSSH2",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")],
            exclude: ["README.md", "COPYING", "vendor-sha256.json"],
            sources: [
                "SSH2Bridge.c",
                "vendor/src/agent.c",
                "vendor/src/bcrypt_pbkdf.c",
                "vendor/src/channel.c",
                "vendor/src/comp.c",
                "vendor/src/chacha.c",
                "vendor/src/cipher-chachapoly.c",
                "vendor/src/crypt.c",
                "vendor/src/crypto.c",
                "vendor/src/global.c",
                "vendor/src/hostkey.c",
                "vendor/src/keepalive.c",
                "vendor/src/kex.c",
                "vendor/src/knownhost.c",
                "vendor/src/mac.c",
                "vendor/src/misc.c",
                "vendor/src/packet.c",
                "vendor/src/pem.c",
                "vendor/src/poly1305.c",
                "vendor/src/publickey.c",
                "vendor/src/scp.c",
                "vendor/src/session.c",
                "vendor/src/sftp.c",
                "vendor/src/transport.c",
                "vendor/src/userauth.c",
                "vendor/src/userauth_kbd_packet.c",
                "vendor/src/version.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendor/include"),
                .headerSearchPath("vendor/src"),
                .headerSearchPath("config"),
                .headerSearchPath("openssl-shims"),
                .define("HAVE_CONFIG_H"),
                .define("LIBSSH2_OPENSSL"),
                .define("LIBSSH2_HAVE_ZLIB"),
                .define("LIBSSH2_DSA_ENABLE"),
                .define("__STDC_WANT_LIB_EXT1__", to: "1"),
                // Libcrypto's umbrella includes obsolete headers; consume only required C headers.
                .unsafeFlags(["-fno-modules"]),
            ],
            linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "GenPlayerFontSupport",
            publicHeadersPath: "include"),
        .target(name: "GenPlayerPiPBridge", publicHeadersPath: "include"),
        .target(
            name: "GenPlayerVLCBridge",
            dependencies: [
                .product(name: "VLCKitSPM", package: "VLCKitPatched"),
            ],
            // include/module.modulemap explicitly lists the public bridge APIs for incremental Xcode builds.
            publicHeadersPath: "include"),
        .target(
            name: "GenPlayerMPVBridge",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit", condition: .when(platforms: [.macOS, .iOS, .tvOS])),
            ],
            exclude: ["README.md", "vendor"],
            sources: ["MetalContext.m", "NativeASSRenderer.m", "NativeASSGeometry.m"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendor/mpv"),
                .headerSearchPath("vendor"),
                .unsafeFlags(["-fobjc-arc", "-fno-modules"]),
            ]),
        .target(
            name: "GenPlayerShell",
            dependencies: [
                "GenPlayerCore",
                "GenPlayerVLCBridge",
                "GenPlayerPiPBridge",
                .product(name: "VLCKitSPM", package: "VLCKitPatched"),
                .target(name: "GenPlayerMPVBridge", condition: .when(platforms: [.macOS, .iOS, .tvOS])),
                .product(name: "MPVKit", package: "MPVKit", condition: .when(platforms: [.macOS, .iOS, .tvOS])),
                .target(name: "GenPlayerFontSupport", condition: .when(platforms: [.tvOS])),
            ],
            resources: [
                .process("Resources"),
            ]),
        .testTarget(
            name: "GenPlayerCoreTests",
            dependencies: ["GenPlayerCore"]),
    ]
)

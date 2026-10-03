# Independent SFTP library

libssh2 1.11.1 from https://libssh2.org/download/libssh2-1.11.1.tar.gz.
Archive SHA-256: `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7`.
Vendored C source/header files are unchanged; `vendor-sha256.json` records their hashes.
Upstream license is retained in COPYING and bundled with GenPlayerShell resources.

The C target builds with Apple SDKs and the existing pinned MPVKit Libcrypto framework.
Private forwarding headers resolve upstream `openssl/...` includes to that framework.
Do not add another OpenSSL binary or silently fall back to VLCKit crypto symbols.
Compression and DSA remain enabled to preserve the existing bundled libssh2 algorithm inventory.
The Swift service imports the upstream C declarations and SFTP attribute type directly;
no handwritten `@_silgen_name` declarations remain. The bridge checks the expected Apple ABI.

Validation: `scripts/check_standalone_ssh2.py` compiles official source for eight Apple
SDK/architecture combinations and compares offline algorithm inventories against VLCKit.
A real Swift/C probe verifies 64-bit timeouts and signed error returns without opening a socket.
App builds and `scripts/check_mac_mpv_linking.py` must additionally verify local libssh2
bindings. These checks do not prove real-server handshake, authentication, browsing,
transfer, cancellation or algorithm interoperability.

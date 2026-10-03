#ifndef GENPLAYER_SSH2_H
#define GENPLAYER_SSH2_H
// Import the upstream ABI rather than redeclaring C functions and structs in Swift.
// These headers expose no OpenSSL types or implementation headers.
#include "../vendor/include/libssh2.h"
#include "../vendor/include/libssh2_sftp.h"
/// Initializes the separately linked libssh2; never opens a socket.
int GPSSH2Initialize(void);
const char *GPSSH2Version(void);
#endif

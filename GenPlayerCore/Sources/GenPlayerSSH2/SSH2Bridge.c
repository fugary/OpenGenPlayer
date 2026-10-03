#include "GenPlayerSSH2.h"
#include "libssh2.h"
#include "libssh2_sftp.h"
#include <stddef.h>
_Static_assert(sizeof(LIBSSH2_SFTP_ATTRIBUTES) == 56, "SFTP Swift attributes layout");
_Static_assert(offsetof(LIBSSH2_SFTP_ATTRIBUTES, filesize) == 8, "SFTP size offset");
_Static_assert(offsetof(LIBSSH2_SFTP_ATTRIBUTES, mtime) == 48, "SFTP time offset");
int GPSSH2Initialize(void) { return libssh2_init(0); }
const char *GPSSH2Version(void) { return libssh2_version(0); }

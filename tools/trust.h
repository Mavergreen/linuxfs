/*
 * Whether root may trust a file it is about to execute, load or read: shared by the bundles' program (fs.c) and the mount
 * daemon. trust.c, libc only.
 */
#ifndef LINUXFS_TRUST_H
#define LINUXFS_TRUST_H

#include <stddef.h>
#include <sys/types.h>

/* Whether root may trust the file at path. The path is walked the way the kernel and dyld walk it, one component at a time,
 * following every symlink by hand: each directory the walk stands in (so the directories holding each symlink hop, as well as
 * the target's own) must be owner's and not writable by anyone else, each symlink must be owner's, and the end must be a regular
 * file that is owner's and writable by it alone. out gets the resolved path, which is what must then be opened or run.
 * 0 when trusted; -1 when something on the way is writable by a user; -2 when it is missing, not a regular file, or too deep.
 * owner is root's uid (a test's stand-in for it in a test build); trust_root, when not NULL, is a directory at or above which
 * nothing is checked (a test's files are under the user's home, not under root's).
 */
int trust_path(const char *path, uid_t owner, const char *trust_root, char *out, size_t outlen);

#endif

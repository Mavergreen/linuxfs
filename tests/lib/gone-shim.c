/*
 * gone-shim.so: an LD_PRELOAD stand-in for a disk pulled out from under lklfuse (lklfuse-gone-linux.sh).
 * Once the file GONE_TRIGGER exists, pread, pwrite, preadv and pwritev on the file GONE_IMAGE (matched by device and inode) fail
 * with ENXIO, as a raw disk's do on macOS after IOKit has terminated its media. Everything else is untouched.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

static int gone(int fd)
{
	const char *t = getenv("GONE_TRIGGER"), *img = getenv("GONE_IMAGE");
	struct stat a, b;

	return t && img && access(t, F_OK) == 0 && fstat(fd, &a) == 0 && stat(img, &b) == 0 &&
	       a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

#define WRAP(name, buftype)                                                                    \
	ssize_t name(int fd, buftype buf, size_t n, off_t off)                                 \
	{                                                                                      \
		static ssize_t (*real)(int, buftype, size_t, off_t);                          \
		if (!real)                                                                     \
			real = (ssize_t (*)(int, buftype, size_t, off_t))dlsym(RTLD_NEXT, #name); \
		if (gone(fd)) {                                                                \
			errno = ENXIO;                                                         \
			return -1;                                                             \
		}                                                                              \
		return real(fd, buf, n, off);                                                  \
	}
WRAP(pread, void *)
WRAP(pread64, void *)
WRAP(pwrite, const void *)
WRAP(pwrite64, const void *)
#define WRAPV(name)                                                                            \
	ssize_t name(int fd, const struct iovec *iov, int n, off_t off)                        \
	{                                                                                      \
		static ssize_t (*real)(int, const struct iovec *, int, off_t);                \
		if (!real)                                                                     \
			real = (ssize_t (*)(int, const struct iovec *, int, off_t))dlsym(RTLD_NEXT, #name); \
		if (gone(fd)) {                                                                \
			errno = ENXIO;                                                         \
			return -1;                                                             \
		}                                                                              \
		return real(fd, iov, n, off);                                                  \
	}
WRAPV(preadv)
WRAPV(preadv64)
WRAPV(pwritev)
WRAPV(pwritev64)

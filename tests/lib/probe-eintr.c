/* platform: host-agnostic -- probe-test.sh's harness for linuxfs_probe_stop (tools/probe.h), built with tools/probe.c and
 * -Dpread=probe_test_pread, so every read of the probe's comes here; the first fails with EINTR, the rest read the file.
 *   usage: probe-eintr IMAGE null|zero|one
 * null leaves linuxfs_probe_stop NULL; zero and one point it at a flag of 0 or 1. Prints the type the probe gave (or NULL)
 * and its error ("EINTR", "-" for none), then "injected 1" when the one EINTR was given.
 */
#include "../../tools/probe.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static int fail_once;

ssize_t probe_test_pread(int fd, void *b, size_t n, off_t off);
ssize_t probe_test_pread(int fd, void *b, size_t n, off_t off)
{
	if (fail_once) {
		fail_once = 0;
		errno = EINTR;
		return -1;
	}
	if (lseek(fd, off, SEEK_SET) < 0)
		return -1;
	return read(fd, b, n);
}

int main(int argc, char **argv)
{
	static volatile sig_atomic_t flag;
	char label[256];
	const char *type;
	int fd, err = 0;

	if (argc != 3 || (fd = open(argv[1], O_RDONLY)) < 0)
		return 2;
	if (strcmp(argv[2], "null") != 0) {
		flag = strcmp(argv[2], "one") == 0;
		linuxfs_probe_stop = &flag;
	}
	fail_once = 1;
	type = linuxfs_probe_fd(fd, label, sizeof label, &err);
	printf("%s %s\ninjected %d\n", type ? type : "NULL", err == EINTR ? "EINTR" : err ? "error" : "-", fail_once == 0);
	return 0;
}

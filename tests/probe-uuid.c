/* platform: host-agnostic
 *   usage: probe-uuid IMAGE            prints linuxfs_probe_uuid for IMAGE, exits 0; prints nothing and exits 1 when none
 *          probe-uuid --small IMAGE    the same with a 36-byte buffer (too small: must be none)
 *          probe-uuid --stale IMAGE BAD  probes IMAGE (must succeed), then BAD; prints a UUID, exits 0, only if one is left over
 */
#include "../tools/probe.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int probe(const char *path)
{
	char lab[512];
	int fd, err;
	const char *t;

	if ((fd = open(path, O_RDONLY)) < 0)
		return -1;
	t = linuxfs_probe_fd(fd, lab, sizeof(lab), &err);
	close(fd);
	return t ? 0 : 1;
}

int main(int argc, char **argv)
{
	char uuid[64];
	size_t outlen = sizeof(uuid);

	if (argc == 3 && strcmp(argv[1], "--small") == 0) {
		outlen = 36;
		argv++, argc--;
	}
	if (argc == 4 && strcmp(argv[1], "--stale") == 0) {
		if (probe(argv[2]) != 0 || linuxfs_probe_uuid(uuid, outlen) < 0)
			return 2;
		probe(argv[3]);
	} else {
		int r = argc == 2 ? probe(argv[1]) : -1;

		if (r != 0)
			return r > 0 ? 1 : 2;
	}
	if (linuxfs_probe_uuid(uuid, outlen) < 0)
		return 1;
	printf("%s\n", uuid);
	return 0;
}

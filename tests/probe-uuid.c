/* platform: host-agnostic
 *   usage: probe-uuid IMAGE
 *          Prints linuxfs_probe_uuid for IMAGE (after linuxfs_probe_fd), exits 0; prints nothing and exits 1 when there is none. */
#include "../tools/probe.h"
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	char lab[512], uuid[64];
	int fd, err;

	if (argc != 2 || (fd = open(argv[1], O_RDONLY)) < 0)
		return 2;
	if (!linuxfs_probe_fd(fd, lab, sizeof(lab), &err) || linuxfs_probe_uuid(uuid, sizeof(uuid)) < 0) {
		close(fd);
		return 1;
	}
	close(fd);
	printf("%s\n", uuid);
	return 0;
}

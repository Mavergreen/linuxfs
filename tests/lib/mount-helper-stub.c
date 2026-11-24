/* platform: macOS-only -- a stand-in for macFUSE's mount_macfuse, for fs-test.sh's -DLINUXFS_FS_TEST_DROP build only
 *   usage: mount-helper-stub -o OPTIONS MNT      (with _FUSE_COMMFD naming its end of the mount program's socket pair)
 * It speaks mount_macfuse's side of libfuse's handshake: one end of a socket pair of its own (the "device") goes back over
 * _FUSE_COMMFD by SCM_RIGHTS with one byte; then, as mount(2) waits for the daemon's INIT, it waits (10 s at most) for a
 * byte from whoever holds that end; then it sends a 4-byte status: 0, or 57 (ENOTCONN) when every holder closed it first.
 * Its environment, arguments, open descriptors and pid go to ARGV0.log; ARGV0.mode, when present, changes what it does:
 *   status N   send N (an errno) instead of 0      nofd     never send the device; sleep 30 s
 *   nostatus   send the device, never a status; sleep 30 s
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv)
{
	char path[1024], mode[64] = "", *e;
	FILE *log, *m;
	int comm, dev[2], fd, i;
	int32_t st = 0;

	snprintf(path, sizeof path, "%s.mode", argv[0]);
	if ((m = fopen(path, "r")) != NULL) {
		if (!fgets(mode, sizeof mode, m))
			mode[0] = '\0';
		fclose(m);
		if ((e = strchr(mode, '\n')) != NULL)
			*e = '\0';
	}
	snprintf(path, sizeof path, "%s.log", argv[0]);
	if ((log = fopen(path, "w")) == NULL)
		return 70;
	fprintf(log, "pid %d\n", (int)getpid());
	for (i = 1; i < argc; i++)
		fprintf(log, "argv %s\n", argv[i]);
	for (i = 0; environ[i]; i++)
		fprintf(log, "env %s\n", environ[i]);
	fprintf(log, "fds");
	for (fd = 0; fd < 256; fd++)
		if (fd != fileno(log) && fcntl(fd, F_GETFD) >= 0)
			fprintf(log, " %d", fd);
	fprintf(log, "\n");
	fflush(log);
	e = getenv("_FUSE_COMMFD");
	if (!e)
		return 71;
	comm = atoi(e);
	if (strcmp(mode, "nofd") == 0) {
		sleep(30);
		return 72;
	}
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, dev) != 0)
		return 73;
	{
		struct msghdr msg;
		struct iovec iov;
		char b = 0, cc[CMSG_SPACE(sizeof(int))];
		struct cmsghdr *c;

		memset(&msg, 0, sizeof msg);
		iov.iov_base = &b;
		iov.iov_len = 1;
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;
		msg.msg_control = cc;
		msg.msg_controllen = sizeof cc;
		c = CMSG_FIRSTHDR(&msg);
		c->cmsg_level = SOL_SOCKET;
		c->cmsg_type = SCM_RIGHTS;
		c->cmsg_len = CMSG_LEN(sizeof(int));
		memcpy(CMSG_DATA(c), &dev[1], sizeof(int));
		if (sendmsg(comm, &msg, 0) != 1)
			return 74;
	}
	close(dev[1]);
	fprintf(log, "sent the device\n");
	fflush(log);
	if (strcmp(mode, "nostatus") == 0) {
		sleep(30);
		return 75;
	}
	{
		struct pollfd p = { dev[0], POLLIN, 0 };
		char b;

		if (poll(&p, 1, 10000) != 1)
			st = ETIMEDOUT;
		else if (read(dev[0], &b, 1) != 1)
			st = ENOTCONN;	/* every holder closed it: no daemon answered */
		else if (strncmp(mode, "status ", 7) == 0)
			st = atoi(mode + 7);
	}
	fprintf(log, "status %d\n", (int)st);
	fflush(log);
	if (write(comm, &st, sizeof st) != (ssize_t)sizeof st)
		return 76;
	return 0;
}

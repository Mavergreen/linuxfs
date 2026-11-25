/* platform: macOS-only -- a stand-in for the bundled CLI's da-mount, for fs-test.sh's -DLINUXFS_FS_TEST_DROP build only
 *   usage: cli-stub ARGS...      (root's channel on fd 6, the disk on 3)
 * It speaks the CLI's side of root's protocol, as linuxfs-open does for the real one: after everything that could fail
 * before the mount (here, nothing but its mode) it writes "R" to fd 6 and waits (10 s at most) for the one descriptor
 * root sends, puts it on fd 4 and answers INIT by writing a byte to it. Its environment, open descriptors (with "sock" for
 * sockets, and "fdpath N PATH" for each one with a path) and pid go to ARGV0.log; ARGV0.mode, when present, changes what it does:
 *   exit N        exit N at once, before "R": a CLI whose preflight failed
 *   noready       neither "R" nor an exit: sleep 30 s
 *   linger        as ok, then leave a sleeper running (logs "lingerer PID") and exit 0
 *   garble        "X" instead of "R", then sleep 30 s
 *   rr            "RR" and trailing bytes in one write, then sleep 30 s: more than "ready"
 *   diesAfterR N  "R", then exit N at once, without waiting for the device
 *   forkchan      "R", then, as the CLI's shell and the opener are two processes: this one closes fd 6 and waits for a child that
 *                 still holds it and takes the device (so the channel never reads closed while the mount is slow), then as ok
 *   afterready N  "R", take the device, and exit N without answering INIT (lklfuse died at startup)
 *   (otherwise)   "R", take the device, answer INIT, print "answered INIT", exit 0
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv)
{
	char path[1024], mode[64] = "", *e, b, cc[CMSG_SPACE(8 * sizeof(int))];
	FILE *log, *m;
	int fd, i, got = -1;
	struct pollfd p;
	struct msghdr mh;
	struct iovec iov;
	struct cmsghdr *cm;
	struct stat st;

	(void)argc;
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
	/* out of the way of fd 4, where the device is to be put */
	fd = fcntl(fileno(log), F_DUPFD, 100);
	fclose(log);
	if (fd < 0 || (log = fdopen(fd, "a")) == NULL)
		return 70;
	fprintf(log, "pid %d\n", (int)getpid());
	for (i = 0; environ[i]; i++)
		fprintf(log, "%s\n", environ[i]);
	fprintf(log, "fds:");
	for (fd = 3; fd < 256; fd++)
		if (fd != fileno(log) && fstat(fd, &st) == 0)
			fprintf(log, " %d%s", fd, S_ISSOCK(st.st_mode) ? ":sock" : "");
	fprintf(log, "\n");
	for (fd = 3; fd < 256; fd++)
		if (fd != fileno(log) && fcntl(fd, F_GETPATH, path) == 0)
			fprintf(log, "fdpath %d %s\n", fd, path);
	fflush(log);
	if (strncmp(mode, "exit", 4) == 0)
		return atoi(mode + 4);
	if (strcmp(mode, "noready") == 0) {
		for (i = 0; i < 300; i++)
			usleep(100000);
		return 1;
	}
	if (strcmp(mode, "garble") == 0 || strcmp(mode, "rr") == 0) {
		const char *g = mode[0] == 'g' ? "X" : "RR\ntrailing";

		if (write(6, g, strlen(g)) < 0)
			return 2;
		for (i = 0; i < 300; i++)
			usleep(100000);
		return 1;
	}
	if (write(6, "R", 1) != 1)
		return 2;
	if (strncmp(mode, "diesAfterR", 10) == 0)
		return atoi(mode + 10);
	if (strcmp(mode, "forkchan") == 0) {
		pid_t k = fork();

		if (k > 0) {
			int ws;

			close(6);
			waitpid(k, &ws, 0);
			return WIFEXITED(ws) ? WEXITSTATUS(ws) : 1;
		}
	}
	p.fd = 6;
	p.events = POLLIN;
	if (poll(&p, 1, 10000) != 1)
		return 3;
	memset(&mh, 0, sizeof mh);
	iov.iov_base = &b;
	iov.iov_len = 1;
	mh.msg_iov = &iov;
	mh.msg_iovlen = 1;
	mh.msg_control = cc;
	mh.msg_controllen = sizeof cc;
	if (recvmsg(6, &mh, 0) != 1 || (cm = CMSG_FIRSTHDR(&mh)) == NULL || cm->cmsg_type != SCM_RIGHTS)
		return 4;
	memcpy(&got, CMSG_DATA(cm), sizeof got);
	if (dup2(got, 4) < 0)
		return 5;
	fprintf(log, "device on 4\n");
	fflush(log);
	if (strncmp(mode, "afterready", 10) == 0)
		return atoi(mode + 10);
	if (write(4, "x", 1) != 1)
		return 6;
	if (strcmp(mode, "linger") == 0) {
		pid_t sp = fork();

		if (sp == 0) {
			for (fd = 0; fd < 256; fd++)
				close(fd);
			sleep(30);
			_exit(0);
		}
		fprintf(log, "lingerer %d\n", (int)sp);
		fflush(log);
		return 0;
	}
	printf("answered INIT\n");
	return 0;
}

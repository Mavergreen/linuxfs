/*
 * linuxfs-open: asks linuxfs-helper to open a disk partition, then runs a program with it as descriptor 3.
 * usage: linuxfs-open [--ro] DEVICE [--also DEVICE2] PROGRAM [ARG...]
 *                                                        runs PROGRAM with the partition open on fd 3 (and
 *                                                        DEVICE2, read-only, on fd 4: an APFS Fusion container's
 *                                                        second device)
 *        linuxfs-open --probe DEVICE                     prints "TYPE<TAB>LABEL[<TAB>FUSION[<TAB>FLAGS]]", as linuxfs-probe does
 *        linuxfs-open --uuid DEVICE                      prints the filesystem's UUID, as linuxfs-probe --uuid does
 *        linuxfs-open --noauto-add SPEC BUNDLE           has the helper add SPEC's noauto entry to /etc/fstab
 *        linuxfs-open --noauto-remove SPEC               has it take that entry away (SPEC: UUID=... or LABEL=...)
 *        linuxfs-open --noauto-remove-all                has it take every linuxfs entry away
 * DEVICE is /dev/rdiskNsM (or /dev/diskNsM, diskNsM). The helper's refusal is printed and exits 1; no helper
 * listening exits 3; misuse exits 2. LINUXFS_HELPER_SOCKET names another socket (tests).
 *
 * With LINUXFS_OPEN_INHERITED=1 (the bundles' mount program, which opened the disk as root before dropping to _linuxfs)
 * fd 3 already is the device and the helper is never contacted: --probe probes fd 3 (pread from offset 0), and
 * [--ro] DEVICE PROGRAM [ARG...] runs PROGRAM with fd 3 as it is. --also exits 1: the partner cannot be probed there.
 * There also --fuse-chan CHAN:FD [--lock FILE] (before DEVICE): the mount program's channel is open on CHAN. linuxfs-open
 * takes FILE's lock (flock, exclusive, without waiting) and KEEPS it: the locked descriptor stays open on fd 7 across the exec,
 * so lklfuse is run with lock=/dev/fd/7; opening /dev/fd/7 duplicates that descriptor (the same open file description: macOS's
 * /dev/fd semantics, checked on 10.9; on Linux the open would be a new description that conflicts with the held lock, so this
 * path is macOS-only, as is everything before login), so lklfuse's own flock succeeds at once while every other process stays excluded, from before
 * "R" until lklfuse ends. It then writes "R" to the channel, waits for the one descriptor root sends over it (the macFUSE
 * device; CHAN_WAIT_S, longer than root's own waits), puts it on FD and runs PROGRAM. What is guaranteed: nobody else can take
 * the lock in between, and a lock held elsewhere, no device, or anything but one descriptor exits 1 with nothing run. What is
 * not: the lock lasts as long as some process holds that open file description (lklfuse, and anything it forks), so a lklfuse
 * that dies leaves it free at once; and root has run no mount_macfuse before "R", so a failure up to there leaves nothing
 * mounted or waiting.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#include "probe.h"

#define DEFAULT_SOCKET "/var/run/dev.mavergreen.linuxfs.helper.sock"

static int usage(void)
{
	fprintf(stderr, "usage: linuxfs-open [--ro] DEVICE [--also DEVICE2] PROGRAM [ARG...]\n       linuxfs-open --probe|--uuid DEVICE\n"
		"       linuxfs-open --noauto-add SPEC BUNDLE\n       linuxfs-open --noauto-remove SPEC\n       linuxfs-open --noauto-remove-all\n");
	return 2;
}

/* diskNsM and /dev/diskNsM become /dev/rdiskNsM; anything else is passed as given. */
static void raw_path(const char *in, char *out, size_t len)
{
	const char *d = strncmp(in, "/dev/", 5) == 0 ? in + 5 : in;

	if (strncmp(d, "disk", 4) == 0)
		snprintf(out, len, "/dev/r%s", d);
	else
		snprintf(out, len, "%s", in);
}

/* Sends REQ; fills ANSWER; returns the received descriptor or -1. Exits 3 when no helper listens. */
static int ask(const char *req, char *answer, size_t len)
{
	const char *path = getenv("LINUXFS_HELPER_SOCKET");
	struct sockaddr_un sa = { 0 };
	struct msghdr mh = { 0 };
	struct iovec iov;
	struct cmsghdr *cm;
	union {
		struct cmsghdr h;
		char buf[64];	/* platform: the 10.9 SDK's CMSG_SPACE is not a constant expression; one int needs far less */
	} ctl;
	ssize_t n;
	int s, fd = -1, secs;
	const char *t = getenv("LINUXFS_OPEN_TIMEOUT");

	if (!path || !*path)
		path = DEFAULT_SOCKET;
	s = socket(AF_UNIX, SOCK_STREAM, 0);
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
	if (s < 0 || connect(s, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		fprintf(stderr, "linuxfs-open: the linuxfs helper is not running (%s: %s)\n", path, strerror(errno));
		exit(3);
	}
	/* review M2: a helper that never answers must not hang the CLI or the agent's probe */
	secs = t && atoi(t) > 0 ? atoi(t) : 20;
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &(struct timeval){ secs, 0 }, sizeof(struct timeval));
	if (write(s, req, strlen(req)) < 0) {
		perror("linuxfs-open");
		exit(3);
	}
	iov.iov_base = answer;
	iov.iov_len = len - 1;
	mh.msg_iov = &iov;
	mh.msg_iovlen = 1;
	mh.msg_control = ctl.buf;
	mh.msg_controllen = CMSG_SPACE(sizeof(int));
	n = recvmsg(s, &mh, 0);
	close(s);
	if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
		fprintf(stderr, "linuxfs-open: the linuxfs helper did not answer in %d seconds\n", secs);
		exit(3);
	}
	if (n <= 0) {
		fprintf(stderr, "linuxfs-open: no answer from the linuxfs helper\n");
		exit(3);
	}
	answer[n] = '\0';
	answer[strcspn(answer, "\n")] = '\0';
	for (cm = CMSG_FIRSTHDR(&mh); cm; cm = CMSG_NXTHDR(&mh, cm))
		if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
			memcpy(&fd, CMSG_DATA(cm), sizeof(int));
	return fd;
}

/* Asks the helper for DEVICE; returns the descriptor, or prints the refusal and returns -1. */
static int open_one(const char *device, int ro)
{
	char dev[256], req[320], answer[1024];
	int fd;

	raw_path(device, dev, sizeof(dev));
	snprintf(req, sizeof(req), "open %s %s\n", dev, ro ? "ro" : "rw");
	fd = ask(req, answer, sizeof(answer));
	if (strncmp(answer, "ok ", 3) != 0 || fd < 0) {
		fprintf(stderr, "linuxfs-open: %s: %s\n", dev, answer + (strncmp(answer, "no ", 3) ? 0 : 3));
		if (fd >= 0)
			close(fd);
		return -1;
	}
	return fd;
}

#define LOCK_FD 7		/* where the held lock stays for lklfuse (cli/linuxfs passes lock=/dev/fd/7) */
/* waiting for root's device: longer than root's own waits (30 s for the CLI's "ready", 30 s for mount_macfuse's device), so root
 * gives up first and says why. Test builds only (-DLINUXFS_OPEN_TEST: tests/helper-test.sh's own copy, never the shipped one),
 * LINUXFS_OPEN_CHAN_TIMEOUT may shorten it, never lengthen it. */
#define CHAN_WAIT_S 45

static int chan_wait_s(void)
{
#ifdef LINUXFS_OPEN_TEST
	const char *t = getenv("LINUXFS_OPEN_CHAN_TIMEOUT");
	char *end;
	long v = t ? strtol(t, &end, 10) : 0;

	if (t && end != t && !*end && v > 0 && v < CHAN_WAIT_S)
		return (int)v;
#endif
	return CHAN_WAIT_S;
}

/* A descriptor number from s, in 4..255 and not 5 (the password's) or LOCK_FD; -1 otherwise. endp gets the end. */
static int fdnum(const char *s, char **endp)
{
	long v = strtol(s, endp, 10);

	return *endp != s && v >= 4 && v <= 255 && v != 5 && v != LOCK_FD ? (int)v : -1;
}

/* --fuse-chan CHAN:FD: the lock is free, "R" to root, and the macFUSE device from root onto FD; 0 when all of it went. */
static int fuse_chan(const char *spec, const char *lock)
{
	int chan, fd, got = -1, nfd = 0, k, i;
	ssize_t r;
	char *colon;
	struct pollfd p;
	struct msghdr mh;
	struct iovec iov;
	struct cmsghdr *cm;
	char b, cc[CMSG_SPACE(8 * sizeof(int))];

	char *end;

	chan = fdnum(spec, &colon);
	if (chan < 0 || *colon != ':' || (fd = fdnum(colon + 1, &end)) < 0 || *end || fd == chan) {
		fprintf(stderr, "linuxfs-open: --fuse-chan wants CHAN:FD, both 4 to 255, not 5 or %d, and different\n", LOCK_FD);
		return -1;
	}
	if (fcntl(chan, F_GETFD) < 0) {
		fprintf(stderr, "linuxfs-open: the channel on fd %d is not open\n", chan);
		return -1;
	}
	if (lock) {
		int lf = open(lock, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0644);

		if (lf < 0 || flock(lf, LOCK_EX | LOCK_NB) != 0) {
			fprintf(stderr, "linuxfs-open: unable to exclusively lock %s\n", lock);
			if (lf >= 0)
				close(lf);
			return -1;
		}
		if (lf != LOCK_FD) {
			if (dup2(lf, LOCK_FD) < 0) {
				close(lf);
				return -1;
			}
			close(lf);
		}
		fcntl(LOCK_FD, F_SETFD, 0);	/* kept across the exec: the lock is held until lklfuse ends */
	}
	if (write(chan, "R", 1) != 1) {
		fprintf(stderr, "linuxfs-open: cannot tell the mount program it is ready\n");
		return -1;
	}
	p.fd = chan;
	p.events = POLLIN;
	for (i = 0; i < chan_wait_s() * 10; i++) {
		p.revents = 0;
		if (poll(&p, 1, 100) > 0 && p.revents)
			break;
	}
	if (!p.revents) {
		fprintf(stderr, "linuxfs-open: no macFUSE device within %d s\n", chan_wait_s());
		return -1;
	}
	memset(&mh, 0, sizeof mh);
	iov.iov_base = &b;
	iov.iov_len = 1;
	mh.msg_iov = &iov;
	mh.msg_iovlen = 1;
	mh.msg_control = cc;
	mh.msg_controllen = sizeof cc;
	r = recvmsg(chan, &mh, MSG_DONTWAIT);
	if (r == 0) {
		fprintf(stderr, "linuxfs-open: root closed the channel without sending the device\n");
		return -1;
	}
	i = r == 1 && !(mh.msg_flags & MSG_CTRUNC) ? 0 : -1;
	for (cm = r >= 0 ? CMSG_FIRSTHDR(&mh) : NULL; cm; cm = CMSG_NXTHDR(&mh, cm)) {
		if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS || cm->cmsg_len < CMSG_LEN(0)) {
			i = -1;
			continue;
		}
		for (k = 0; k < (int)((cm->cmsg_len - CMSG_LEN(0)) / sizeof(int)); k++) {
			int one;

			memcpy(&one, CMSG_DATA(cm) + k * sizeof(int), sizeof one);
			if (nfd++ == 0)
				got = one;
			else
				close(one);
		}
	}
	if (i < 0 || nfd != 1) {
		if (got >= 0)
			close(got);
		fprintf(stderr, "linuxfs-open: root's message was not one macFUSE device\n");
		return -1;
	}
	if (got != fd && dup2(got, fd) < 0) {
		close(got);
		return -1;
	}
	if (got != fd)
		close(got);
	fcntl(fd, F_SETFD, 0);
	close(chan);
	return 0;
}

/* Inherited mode: fd 3 is the device. Returns main's exit status, or never returns (the exec). */
static int inherited(int argc, char **argv)
{
	int i = 1;

	if (fcntl(3, F_GETFD) < 0) {
		fprintf(stderr, "linuxfs-open: LINUXFS_OPEN_INHERITED=1 but fd 3 is not open\n");
		return 1;
	}
	if (argc >= 2 && strncmp(argv[1], "--noauto-", 9) == 0) {
		fprintf(stderr, "linuxfs-open: /etc/fstab is not edited before login\n");
		return 1;
	}
	if (argc == 3 && (strcmp(argv[1], "--probe") == 0 || strcmp(argv[1], "--uuid") == 0)) {
		char label[256], uuid[40], line[400];
		const char *type;
		int err = 0;

		type = linuxfs_probe_fd(3, label, sizeof(label), &err);
		if (!type) {
			fprintf(stderr, "linuxfs-open: fd 3: %s\n", err ? strerror(err) : "no filesystem linuxfs knows");
			if (argv[1][2] == 'p')
				printf("unknown\n");
			return 1;
		}
		if (argv[1][2] == 'u') {
			if (linuxfs_probe_uuid(uuid, sizeof(uuid)) != 0) {
				fprintf(stderr, "linuxfs-open: fd 3: this filesystem has no UUID\n");
				return 1;
			}
			printf("%s\n", uuid);
			return 0;
		}
		if (linuxfs_probe_line(line, sizeof(line), type, label) != 0)
			return 1;
		printf("%s\n", line);
		return 0;
	}
	{
		const char *chan = NULL, *lock = NULL;

		for (;;) {
			if (i + 1 < argc && strcmp(argv[i], "--fuse-chan") == 0)
				chan = argv[i + 1], i += 2;
			else if (i + 1 < argc && strcmp(argv[i], "--lock") == 0)
				lock = argv[i + 1], i += 2;
			else if (i < argc && strcmp(argv[i], "--ro") == 0)
				i++;
			else
				break;
		}
		if (argc - i < 2 || (lock && !chan))
			return usage();
		if (chan && fuse_chan(chan, lock) != 0)
			return 1;
	}
	i++;	/* DEVICE: fd 3 is it already */
	if (strcmp(argv[i], "--also") == 0) {
		fprintf(stderr, "linuxfs-open: --also is not available before login (the partner cannot be probed)\n");
		return 1;
	}
	execv(argv[i], argv + i);
	fprintf(stderr, "linuxfs-open: %s: %s\n", argv[i], strerror(errno));
	return 127;
}

int main(int argc, char **argv)
{
	char dev[256], req[320], answer[1024];
	const char *main_dev, *also_dev = NULL, *inh = getenv("LINUXFS_OPEN_INHERITED");
	int i = 1, ro = 0, fd, fd2;

	if (inh && strcmp(inh, "1") == 0)
		return inherited(argc, argv);

	if (argc == 3 && (strcmp(argv[1], "--probe") == 0 || strcmp(argv[1], "--uuid") == 0)) {
		int probe = argv[1][2] == 'p';

		raw_path(argv[2], dev, sizeof(dev));
		snprintf(req, sizeof(req), "%s %s\n", probe ? "probe" : "uuid", dev);
		fd = ask(req, answer, sizeof(answer));
		if (fd >= 0)
			close(fd);
		if (strncmp(answer, "ok ", 3) != 0) {
			fprintf(stderr, "linuxfs-open: %s: %s\n", dev, answer + (strncmp(answer, "no ", 3) ? 0 : 3));
			if (probe)
				printf("unknown\n");
			return 1;
		}
		printf("%s\n", answer + 3);
		return 0;
	}
	if ((argc == 4 && strcmp(argv[1], "--noauto-add") == 0) || (argc == 3 && strcmp(argv[1], "--noauto-remove") == 0) ||
	    (argc == 2 && strcmp(argv[1], "--noauto-remove-all") == 0)) {
		char line[2048];

		/* the helper checks SPEC and BUNDLE, and refuses a request of more than one line */
		if (argc == 2)
			snprintf(line, sizeof(line), "noauto-remove-all\n");
		else if (snprintf(line, sizeof(line), "%s %s%s%s\n", argv[1] + 2, argv[2], argc == 4 ? " " : "", argc == 4 ? argv[3] : "") >= (int)sizeof(line)) {
			fprintf(stderr, "linuxfs-open: the volume's name is too long\n");
			return 1;
		}
		fd = ask(line, answer, sizeof(answer));
		if (fd >= 0)
			close(fd);
		if (strcmp(answer, "ok") != 0) {
			fprintf(stderr, "linuxfs-open: %s\n", answer + (strncmp(answer, "no ", 3) ? 0 : 3));
			return 1;
		}
		return 0;
	}
	if (argc >= 2 && strncmp(argv[1], "--noauto-", 9) == 0)
		return usage();
	if (i < argc && strcmp(argv[i], "--ro") == 0) {
		ro = 1;
		i++;
	}
	if (argc - i < 2)
		return usage();
	main_dev = argv[i++];
	if (i + 1 < argc && strcmp(argv[i], "--also") == 0) {
		also_dev = argv[i + 1];
		i += 2;
	}
	if (i >= argc)
		return usage();
	fd = open_one(main_dev, ro);
	fd2 = also_dev ? open_one(also_dev, 1) : -1;
	if (fd < 0 || (also_dev && fd2 < 0))
		return 1;
	/* above 4 first, so placing one cannot close the other */
	fd = fcntl(fd, F_DUPFD, 10);
	if (fd2 >= 0)
		fd2 = fcntl(fd2, F_DUPFD, 10);
	if (fd < 0 || dup2(fd, 3) < 0 || (fd2 >= 0 && dup2(fd2, 4) < 0)) {
		perror("linuxfs-open: dup2");
		return 1;
	}
	close(fd);
	fcntl(3, F_SETFD, 0);
	if (fd2 >= 0) {
		close(fd2);
		fcntl(4, F_SETFD, 0);
	}
	execv(argv[i], argv + i);
	fprintf(stderr, "linuxfs-open: %s: %s\n", argv[i], strerror(errno));
	return 127;
}

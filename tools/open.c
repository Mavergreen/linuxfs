/*
 * linuxfs-open: asks linuxfs-helper to open a disk partition, then runs a program with it as descriptor 3.
 * usage: linuxfs-open [--ro] DEVICE [--also DEVICE2] PROGRAM [ARG...]
 *                                                        runs PROGRAM with the partition open on fd 3 (and
 *                                                        DEVICE2, read-only, on fd 4: an APFS Fusion container's
 *                                                        second device)
 *        linuxfs-open --probe DEVICE                     prints "TYPE<TAB>LABEL", as linuxfs-probe does
 *        linuxfs-open --uuid DEVICE                      prints the filesystem's UUID, as linuxfs-probe --uuid does
 *        linuxfs-open --noauto-add SPEC BUNDLE           has the helper add SPEC's noauto entry to /etc/fstab
 *        linuxfs-open --noauto-remove SPEC               has it take that entry away (SPEC: UUID=... or LABEL=...)
 * DEVICE is /dev/rdiskNsM (or /dev/diskNsM, diskNsM). The helper's refusal is printed and exits 1; no helper
 * listening exits 3; misuse exits 2. LINUXFS_HELPER_SOCKET names another socket (tests).
 *
 * With LINUXFS_OPEN_INHERITED=1 (the bundles' mount program, which opened the disk as root before dropping to _linuxfs)
 * fd 3 already is the device and the helper is never contacted: --probe probes fd 3 (pread from offset 0), and
 * [--ro] DEVICE PROGRAM [ARG...] runs PROGRAM with fd 3 as it is. --also exits 1: the partner cannot be probed there.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#include "probe.h"

#define DEFAULT_SOCKET "/var/run/dev.mavergreen.linuxfs.helper.sock"

static int usage(void)
{
	fprintf(stderr, "usage: linuxfs-open [--ro] DEVICE [--also DEVICE2] PROGRAM [ARG...]\n       linuxfs-open --probe|--uuid DEVICE\n"
		"       linuxfs-open --noauto-add SPEC BUNDLE\n       linuxfs-open --noauto-remove SPEC\n");
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
		char label[256], uuid[40];
		const char *type, *extra;
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
		extra = linuxfs_probe_extra();
		if (extra && *extra)
			printf("%s\t%s\t%s\n", type, label, extra);
		else
			printf("%s\t%s\n", type, label);
		return 0;
	}
	if (i < argc && strcmp(argv[i], "--ro") == 0)
		i++;
	if (argc - i < 2)
		return usage();
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
	if ((argc == 4 && strcmp(argv[1], "--noauto-add") == 0) || (argc == 3 && strcmp(argv[1], "--noauto-remove") == 0)) {
		char line[2048];

		/* the helper checks SPEC and BUNDLE, and refuses a request of more than one line */
		if (snprintf(line, sizeof(line), "%s %s%s%s\n", argv[1] + 2, argv[2], argc == 4 ? " " : "", argc == 4 ? argv[3] : "") >= (int)sizeof(line)) {
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

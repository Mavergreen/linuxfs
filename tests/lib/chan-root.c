/* platform: macOS-only -- a stand-in for the mount program's side of the CLI's channel, for helper-test.sh
 *   usage: chan-root MODE PROGRAM [ARG...]
 * Runs PROGRAM with a socket on fd 6 (its end of the channel) and, as root does, waits up to 5 s for "R" from it, then
 * (MODE device) sends one descriptor, the write end of a pipe, (two) two descriptors, (none) nothing, or (close) closes
 * its end of the channel without sending; then waits up to
 * 5 s for PROGRAM and for a byte on the pipe. Prints: "ready" or "not ready", "byte B" when one came through the pipe,
 * and "exit N". */
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static int send_fds(int sock, int *fds, int n)
{
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *c;
	char b = 'D', cc[CMSG_SPACE(2 * sizeof(int))];

	memset(&msg, 0, sizeof msg);
	memset(cc, 0, sizeof cc);
	iov.iov_base = &b;
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cc;
	msg.msg_controllen = CMSG_SPACE((size_t)n * sizeof(int));
	c = CMSG_FIRSTHDR(&msg);
	c->cmsg_level = SOL_SOCKET;
	c->cmsg_type = SCM_RIGHTS;
	c->cmsg_len = CMSG_LEN((size_t)n * sizeof(int));
	memcpy(CMSG_DATA(c), fds, (size_t)n * sizeof(int));
	return sendmsg(sock, &msg, 0) == 1;
}

int main(int argc, char **argv)
{
	int sv[2], pp[2], pp2[2], st = 0, i, rc = 0;
	pid_t pid;
	struct pollfd p;
	char b;

	if (argc < 3 || socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0 || pipe(pp) != 0 || pipe(pp2) != 0)
		return 2;
	pid = fork();
	if (pid == 0) {
		close(sv[0]);
		close(pp[0]);
		close(pp[1]);
		close(pp2[0]);
		close(pp2[1]);
		dup2(sv[1], 6);
		execv(argv[2], argv + 2);
		_exit(127);
	}
	close(sv[1]);
	p.fd = sv[0];
	p.events = POLLIN;
	if (poll(&p, 1, 5000) == 1 && read(sv[0], &b, 1) == 1 && b == 'R') {
		int two[2] = { pp[1], pp2[1] };

		printf("ready\n");
		fflush(stdout);
		if (strcmp(argv[1], "device") == 0)
			send_fds(sv[0], &pp[1], 1);
		else if (strcmp(argv[1], "two") == 0)
			send_fds(sv[0], two, 2);
		else if (strcmp(argv[1], "close") == 0)
			close(sv[0]);
	} else {
		printf("not ready\n");
	}
	close(pp[1]);
	close(pp2[1]);
	for (i = 0; i < 50; i++) {
		if (waitpid(pid, &st, WNOHANG) == pid) {
			rc = WIFEXITED(st) ? WEXITSTATUS(st) : 255;
			break;
		}
		usleep(100000);
	}
	if (i == 50) {
		kill(pid, 9);
		waitpid(pid, &st, 0);
		rc = 124;
	}
	p.fd = pp[0];
	if (poll(&p, 1, 1000) == 1 && read(pp[0], &b, 1) == 1)
		printf("byte %c\n", b);
	printf("exit %d\n", rc);
	return 0;
}

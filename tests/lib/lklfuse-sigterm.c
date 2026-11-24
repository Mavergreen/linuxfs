/*
 * Serves lklfuse an ext4 image on descriptor 3 and a socketpair standing in for the macFUSE device on 4 (a
 * "/dev/fd/4" mountpoint libfuse adopts: no mount, no kext, no root), lets it settle, sends SIGTERM and times its end.
 *   usage: lklfuse-sigterm LKLFUSE IMAGE SETTLE_S DEADLINE_MS
 * Prints "exited MS status=N" and exits 0 when lklfuse ended within the deadline, "hung" and 2 when it did not (it is
 * killed), 1 on any other trouble. The environment (DYLD_*) is lklfuse's.
 */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

static double now_ms(void)
{
	struct timeval t;

	gettimeofday(&t, NULL);
	return t.tv_sec * 1000.0 + t.tv_usec / 1000.0;
}

int main(int argc, char **argv)
{
	int sv[2], st, i, disk;
	pid_t p;
	double t0, deadline;

	if (argc != 5) {
		fprintf(stderr, "usage: lklfuse-sigterm LKLFUSE IMAGE SETTLE_S DEADLINE_MS\n");
		return 1;
	}
	deadline = atof(argv[4]);
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0 || (disk = open(argv[2], O_RDWR)) < 0) {
		perror("setup");
		return 1;
	}
	p = fork();
	if (p == 0) {
		if (dup2(disk, 3) < 0 || dup2(sv[1], 4) < 0)
			_exit(127);
		for (i = 5; i < 256; i++)
			close(i);
		execl(argv[1], "lklfuse", "-f", "-o", "type=ext4", "/dev/fd/3", "/dev/fd/4", (char *)NULL);
		_exit(127);
	}
	if (p < 0) {
		perror("fork");
		return 1;
	}
	close(sv[1]);
	sleep(atoi(argv[3]));
	if (waitpid(p, &st, WNOHANG) == p) {
		printf("died before SIGTERM, status=%d\n", st);
		return 1;
	}
	t0 = now_ms();
	kill(p, SIGTERM);
	for (;;) {
		if (waitpid(p, &st, WNOHANG) == p) {
			printf("exited %.0f status=%d\n", now_ms() - t0, WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st));
			return now_ms() - t0 <= deadline ? 0 : 2;
		}
		if (now_ms() - t0 > deadline) {
			kill(p, SIGKILL);
			waitpid(p, &st, 0);
			printf("hung\n");
			return 2;
		}
		usleep(10000);
	}
}

/* platform: macOS-only -- a stand-in for a bundle's mount_macfuse_<fs>, for mountd-test.sh's LINUXFS_MOUNTD_TEST daemon only
 *   usage: mount_macfuse_<fs> -o OPTIONS /dev/BSD MNT       (copied as DIR/mount_macfuse_ext4, DIR/mount_macfuse_btrfs, ...)
 * The daemon gives it PATH alone, so what it does comes from DIR/mode (one word, or a word and a number, per line), and it
 * writes to DIR/log: its pid, argv, environment, open descriptors ("fds 0 1 2"), SIGPIPE's disposition, and what it did.
 * With no mode, it exits 0.
 *   mount        append root's mount of /dev/BSD on MNT to DIR/mnttab (TYPE<TAB>FROM<TAB>ON<TAB>OWNER: macfuse_<fs>, owner 0)
 *   owner N      the line's owner is N            from DEV   the line's source is DEV
 *   exit N       exit N                           sleep N    sleep N s before exiting
 *   chatty       write 1 MiB to stdout first, in lines of 1 KiB
 *   ignoreterm   SIGTERM is logged ("sigterm") and ignored     termexit   SIGTERM is logged and ends it (exit 143)
 *   child        a "mount_macfuse" child in its own group (the program's), sleeping 30 s ("child PID")
 *   cli          a "CLI" child leading a group of its own (setpgid), sleeping 30 s ("cli PID"); prints "cli-pgid PID"
 *   pgidline N   print "cli-pgid N", starting nothing (a CLI group the test's process table stands in for)
 *   cliend       the same, but the CLI ends after 1 s and is reaped; then, 2.5 s later, a fresh group of its own
 *                ("fresh PID", sleeping 30 s) is named by a second line, "cli-pgid FRESH"
 */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static char dir[1024];
static volatile sig_atomic_t termexit;

static void logline(const char *fmt, long v)
{
	char path[1100];
	FILE *f;

	snprintf(path, sizeof path, "%s/log", dir);
	if ((f = fopen(path, "a")) != NULL) {
		fprintf(f, fmt, v);
		fputc('\n', f);
		fclose(f);
	}
}

static void on_term(int sig)
{
	char path[1100];
	int fd;

	(void)sig;
	snprintf(path, sizeof path, "%s/log", dir);
	if ((fd = open(path, O_WRONLY | O_APPEND)) >= 0) {
		if (write(fd, "sigterm\n", 8) < 0) {
			/* nothing to do */
		}
		close(fd);
	}
	if (termexit)
		_exit(143);
}

static pid_t sleeper(int own_group)
{
	pid_t p = fork();

	if (p == 0) {
		signal(SIGTERM, SIG_DFL);
		if (own_group)
			setpgid(0, 0);
		sleep(30);
		_exit(0);
	}
	if (p > 0 && own_group)
		setpgid(p, p);
	return p;
}

int main(int argc, char **argv)
{
	char path[1100], line[128], *slash;
	long pgidline = 0;
	int fd, exitn = 0, sleepn = 0, mount = 0, chatty = 0, ignore = 0, child = 0, cli = 0, cliend = 0, i;
	long owner = 0;
	char from[1024] = "";
	FILE *f, *log;

	snprintf(dir, sizeof dir, "%s", argv[0]);
	if ((slash = strrchr(dir, '/')) != NULL)
		*slash = '\0';
	snprintf(path, sizeof path, "%s/mode", dir);
	if ((f = fopen(path, "r")) != NULL) {
		while (fgets(line, sizeof line, f)) {
			char w[64] = "", a[1024] = "";

			if (sscanf(line, "%63s %1023s", w, a) < 1)
				continue;
			if (!strcmp(w, "mount")) mount = 1;
			else if (!strcmp(w, "owner")) owner = atol(a);
			else if (!strcmp(w, "from")) snprintf(from, sizeof from, "%s", a);
			else if (!strcmp(w, "exit")) exitn = atoi(a);
			else if (!strcmp(w, "sleep")) sleepn = atoi(a);
			else if (!strcmp(w, "chatty")) chatty = 1;
			else if (!strcmp(w, "ignoreterm")) ignore = 1;
			else if (!strcmp(w, "termexit")) termexit = 1;
			else if (!strcmp(w, "child")) child = 1;
			else if (!strcmp(w, "cli")) cli = 1;
			else if (!strcmp(w, "cliend")) cliend = 1;
			else if (!strcmp(w, "pgidline")) pgidline = atol(a);
		}
		fclose(f);
	}
	/* what it was given, before it opens anything of its own */
	snprintf(path, sizeof path, "%s/log", dir);
	{
		char fds[1024] = "fds";
		size_t n = 3;

		for (fd = 0; fd < 256; fd++)
			if (fcntl(fd, F_GETFD) >= 0)
				n += (size_t)snprintf(fds + n, sizeof fds - n, " %d", fd);
		if ((log = fopen(path, "w")) == NULL)
			return 70;
		fprintf(log, "pid %d\npgid %d\n", (int)getpid(), (int)getpgrp());
		for (i = 1; i < argc; i++)
			fprintf(log, "argv %s\n", argv[i]);
		for (i = 0; environ[i]; i++)
			fprintf(log, "env %s\n", environ[i]);
		fprintf(log, "%s\n", fds);
		{
			struct sigaction old;

			sigaction(SIGPIPE, NULL, &old);
			fprintf(log, "sigpipe %s\n", old.sa_handler == SIG_DFL ? "default" : "not default");
		}
		fclose(log);
	}
	if (ignore || termexit) {
		struct sigaction sa;

		memset(&sa, 0, sizeof sa);
		sa.sa_handler = on_term;
		sigaction(SIGTERM, &sa, NULL);
	}
	if (chatty) {
		char buf[1024];

		memset(buf, 'x', sizeof buf - 1);
		buf[sizeof buf - 1] = '\n';
		for (i = 0; i < 1024; i++)
			if (write(1, buf, sizeof buf) != (ssize_t)sizeof buf)
				return 72;
	}
	if (mount && argc >= 3) {
		const char *base = strrchr(argv[0], '/');

		base = base ? base + 1 : argv[0];
		snprintf(path, sizeof path, "%s/mnttab", dir);
		if (strncmp(base, "mount_", 6) != 0 || (f = fopen(path, "a")) == NULL)
			return 78;
		fprintf(f, "%s\t%s\t%s\t%ld\n", base + 6, *from ? from : argv[argc - 2], argv[argc - 1], owner);
		fclose(f);
	}
	if (pgidline) {
		printf("cli-pgid %ld\n", pgidline);
		fflush(stdout);
	}
	if (child)
		logline("child %ld", (long)sleeper(0));
	if (cli || cliend) {
		pid_t c = sleeper(1);

		logline("cli %ld", (long)c);
		printf("cli-pgid %ld\n", (long)c);
		fflush(stdout);
		if (cliend) {
			int st;

			sleep(1);
			kill(c, SIGKILL);
			waitpid(c, &st, 0);
			logline("cli ended %ld", (long)c);
			usleep(2500000);
			c = sleeper(1);
			logline("fresh %ld", (long)c);
			printf("cli-pgid %ld\n", (long)c);
			fflush(stdout);
		}
	}
	for (i = 0; i < sleepn * 10; i++)
		usleep(100000);
	return exitn;
}

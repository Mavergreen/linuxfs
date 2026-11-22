/* platform: host-agnostic */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <lkl.h>
#include <lkl_host.h>

#define MiB (1024L * 1024L)
#define DATA_LEN (4 * MiB)
#define MANY 2000
#define DEEP 64
#define BIG_OFFSET ((long long)(7.9 * 1024 * MiB))
#define BIG_LEN MiB
/* On the raw device: past 32 bits, so a truncated offset would land at 0.5 GiB instead. */
#define RAW_OFFSET (4LL * 1024 * MiB + 512 * MiB)
#define ODD_NAME "na\xc3\xafve-caf\xc3\xa9"

static int failures, tapno;

static double now_ms(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1e3 + tv.tv_usec / 1e3;
}

static void timing(const char *what, double start, double bytes)
{
	double ms = now_ms() - start;
	printf("# time %s: %.0f ms", what, ms);
	if (bytes > 0)
		printf(", %.1f MiB/s", bytes / MiB / (ms / 1e3));
	printf("\n");
}
static char mnt[256];

static void tap(int ok, const char *what, long detail)
{
	printf("%s %d - %s", ok ? "ok" : "not ok", ++tapno, what);
	if (!ok)
		printf(" (%ld: %s)", detail, detail < 0 ? lkl_strerror(detail) : "");
	printf("\n");
	fflush(stdout);
	if (!ok)
		failures++;
}

static unsigned char pattern(long long i)
{
	return (unsigned char)((i * 31 + 7) ^ (i >> 12));
}

static const char *at(const char *rel)
{
	static char buf[4][1024];
	static int n;
	char *b = buf[n++ % 4];
	snprintf(b, 1024, "%s/%s", mnt, rel);
	return b;
}

static long write_pattern(const char *path, long long off, long len, long chunk)
{
	static unsigned char buf[MiB];
	long fd = lkl_sys_open(path, LKL_O_CREAT | LKL_O_WRONLY, 0644), r = 0;
	if (fd < 0)
		return fd;
	for (long done = 0; done < len && r >= 0; done += chunk) {
		long n = len - done < chunk ? len - done : chunk;
		for (long i = 0; i < n; i++)
			buf[i] = pattern(off + done + i);
		r = lkl_sys_pwrite64(fd, (char *)buf, n, off + done);
		if (r >= 0 && r != n)
			r = -LKL_EIO;
	}
	if (r >= 0)
		r = lkl_sys_fsync(fd);
	lkl_sys_close(fd);
	return r < 0 ? r : 0;
}

static long check_pattern(const char *path, long long off, long len)
{
	static unsigned char buf[MiB];
	long fd = lkl_sys_open(path, LKL_O_RDONLY, 0), r = 0;
	if (fd < 0)
		return fd;
	for (long done = 0; done < len && r >= 0; done += MiB) {
		long n = len - done < MiB ? len - done : MiB;
		r = lkl_sys_pread64(fd, (char *)buf, n, off + done);
		if (r >= 0 && r != n)
			r = -LKL_EIO;
		for (long i = 0; r >= 0 && i < n; i++)
			if (buf[i] != pattern(off + done + i))
				r = -LKL_EBADMSG;
	}
	lkl_sys_close(fd);
	return r < 0 ? r : 0;
}

static long write_small(const char *path, const char *text)
{
	long fd = lkl_sys_open(path, LKL_O_CREAT | LKL_O_WRONLY | LKL_O_TRUNC, 0644);
	if (fd < 0)
		return fd;
	long r = lkl_sys_write(fd, text, strlen(text));
	lkl_sys_close(fd);
	return r == (long)strlen(text) ? 0 : (r < 0 ? r : -LKL_EIO);
}

static long check_small(const char *path, const char *text)
{
	char buf[256] = {0};
	long fd = lkl_sys_open(path, LKL_O_RDONLY, 0);
	if (fd < 0)
		return fd;
	long r = lkl_sys_read(fd, buf, sizeof(buf) - 1);
	lkl_sys_close(fd);
	if (r < 0)
		return r;
	return strcmp(buf, text) == 0 ? 0 : -LKL_EBADMSG;
}

static void phase_write(void)
{
	char rel[1024];
	long r;

	r = lkl_sys_mkdir(at("a"), 0755);
	if (r == 0) r = lkl_sys_mkdir(at("a/b"), 0755);
	if (r == 0) r = lkl_sys_mkdir(at("a/b/c"), 0755);
	tap(r == 0, "nested directories created", r);

	double t0 = now_ms();
	r = write_pattern(at("a/b/c/data.bin"), 0, DATA_LEN / 2, 4096);
	if (r == 0) {
		static unsigned char buf[MiB];
		long fd = lkl_sys_open(at("a/b/c/data.bin"), LKL_O_WRONLY, 0);
		for (long done = DATA_LEN / 2; fd >= 0 && r == 0 && done < DATA_LEN; done += MiB) {
			for (long i = 0; i < MiB; i++)
				buf[i] = pattern(done + i);
			long w = lkl_sys_pwrite64(fd, (char *)buf, MiB, done);
			r = w == MiB ? 0 : (w < 0 ? w : -LKL_EIO);
		}
		if (fd >= 0) { if (r == 0) r = lkl_sys_fsync(fd); lkl_sys_close(fd); }
		else r = fd;
	}
	timing("4 MiB file, fsynced", t0, DATA_LEN);
	tap(r == 0, "4 MiB file written in 4 KiB and 1 MiB chunks", r);

	r = lkl_sys_rename(at("a/b/c/data.bin"), at("a/b/c/renamed.bin"));
	tap(r == 0, "rename", r);
	r = lkl_sys_symlink("renamed.bin", at("a/b/c/link"));
	tap(r == 0, "symlink", r);
	r = lkl_sys_link(at("a/b/c/renamed.bin"), at("a/b/c/hard"));
	tap(r == 0, "hard link", r);
	r = lkl_sys_chmod(at("a/b/c/renamed.bin"), 0640);
	tap(r == 0, "chmod 0640", r);
	r = lkl_sys_chown(at("a/b/c/renamed.bin"), 1000, 1000);
	tap(r == 0, "chown 1000:1000", r);

	t0 = now_ms();
	r = lkl_sys_mkdir(at("many"), 0755);
	for (int i = 0; r == 0 && i < MANY; i++) {
		snprintf(rel, sizeof(rel), "many/f%04d", i);
		r = write_small(at(rel), rel);
	}
	lkl_sys_sync();
	timing("2000 small files, synced", t0, 0);
	tap(r == 0, "2000 small files in one directory", r);

	strcpy(rel, "deep");
	r = lkl_sys_mkdir(at(rel), 0755);
	for (int i = 0; r == 0 && i < DEEP; i++) {
		size_t n = strlen(rel);
		snprintf(rel + n, sizeof(rel) - n, "/d%d", i);
		r = lkl_sys_mkdir(at(rel), 0755);
	}
	tap(r == 0, "64-level directory chain", r);

	r = write_small(at(ODD_NAME), "x");
	tap(r == 0, "non-ASCII file name", r);

	lkl_sys_sync();
}

static void phase_verify(void)
{
	char rel[1024], buf[256] = {0};
	struct lkl_stat a, b;
	long r;

	r = check_pattern(at("a/b/c/renamed.bin"), 0, DATA_LEN);
	tap(r == 0, "4 MiB content intact after rename", r);
	r = lkl_sys_stat(at("a/b/c/data.bin"), &a);
	tap(r == -LKL_ENOENT, "old name gone after rename", r);
	r = lkl_sys_readlink(at("a/b/c/link"), buf, sizeof(buf) - 1);
	tap(r == (long)strlen("renamed.bin") && strcmp(buf, "renamed.bin") == 0, "symlink target", r);
	r = lkl_sys_stat(at("a/b/c/renamed.bin"), &a);
	if (r == 0) r = lkl_sys_stat(at("a/b/c/hard"), &b);
	tap(r == 0 && a.st_ino == b.st_ino && a.st_nlink == 2, "hard link shares inode, nlink 2", r ? r : (long)a.st_nlink);
	tap(r == 0 && (a.st_mode & 07777) == 0640, "mode 0640", r ? r : (long)(a.st_mode & 07777));
	tap(r == 0 && a.st_uid == 1000 && a.st_gid == 1000, "owner 1000:1000", r ? r : (long)a.st_uid);

	int count = 0, bad = 0;
	struct lkl_dir *d = lkl_opendir(at("many"), &bad);
	for (struct lkl_linux_dirent64 *de = d ? lkl_readdir(d) : NULL; de; de = lkl_readdir(d))
		if (strcmp(de->d_name, ".") && strcmp(de->d_name, ".."))
			count++;
	if (d) lkl_closedir(d);
	tap(bad == 0 && count == MANY, "2000 entries listed", bad ? bad : count);
	for (int i = 0, r2 = 0; i < MANY; i += 499) {
		snprintf(rel, sizeof(rel), "many/f%04d", i);
		r2 = check_small(at(rel), rel);
		if (r2) { tap(0, "small file content", r2); break; }
	}

	strcpy(rel, "deep");
	for (int i = 0; i < DEEP; i++) {
		size_t n = strlen(rel);
		snprintf(rel + n, sizeof(rel) - n, "/d%d", i);
	}
	r = lkl_sys_stat(at(rel), &a);
	tap(r == 0 && LKL_S_ISDIR(a.st_mode), "64th directory level present", r);

	r = check_small(at(ODD_NAME), "x");
	tap(r == 0, "non-ASCII name and content preserved", r);

}

static void phase_verify_large(void)
{
	long r = check_pattern(at("big.bin"), BIG_OFFSET, BIG_LEN);
	tap(r == 0, "1 MiB at 7.9 GiB intact", r);
}

static void phase_large_offset(void)
{
	long r = write_pattern(at("big.bin"), BIG_OFFSET, BIG_LEN, MiB);
	tap(r == 0, "1 MiB written at 7.9 GiB", r);
	lkl_sys_sync();
}

static void phase_churn(void)
{
	char rel[64];
	long r = lkl_sys_mkdir(at("churn"), 0755);
	tap(r == 0 || r == -LKL_EEXIST, "churn directory", r);
	for (long i = 0;; i++) {
		snprintf(rel, sizeof(rel), "churn/c%ld", i % 4000);
		r = write_pattern(at(rel), 0, 64 * 1024, 64 * 1024);
		if (r) { tap(0, "churn write", r); return; }
		if (i % 100 == 0) { printf("# churn %ld\n", i); fflush(stdout); }
	}
}

static void phase_raw_large(int id)
{
	uint32_t dev;
	long r = lkl_get_virtio_blkdev(id, 0, &dev);

	if (r == 0)
		r = lkl_sys_mknod("/rawdev", LKL_S_IFBLK | 0600, dev);
	if (r == 0)
		r = write_pattern("/rawdev", RAW_OFFSET, BIG_LEN, MiB);
	tap(r == 0, "1 MiB written to the raw device at 4.5 GiB", r);
	r = check_pattern("/rawdev", RAW_OFFSET, BIG_LEN);
	tap(r == 0, "1 MiB read back from the raw device at 4.5 GiB", r);
}

/* After the kernel is gone: the host file must hold the bytes at 4.5 GiB, and nothing at 0.5 GiB. */
static void host_check_raw(int fd)
{
	static unsigned char buf[BIG_LEN];
	long bad = 0;

	if (pread(fd, buf, BIG_LEN, RAW_OFFSET) != BIG_LEN)
		bad = -1;
	for (long i = 0; !bad && i < BIG_LEN; i++)
		if (buf[i] != pattern(RAW_OFFSET + i))
			bad = i + 1;
	tap(!bad, "host file holds the pattern at 4.5 GiB", bad);
	bad = pread(fd, buf, BIG_LEN, RAW_OFFSET & 0xffffffffLL) == BIG_LEN ? 0 : -1;
	for (long i = 0; !bad && i < BIG_LEN; i++)
		if (buf[i])
			bad = i + 1;
	tap(!bad, "host file untouched at 0.5 GiB (no 32-bit truncation)", bad);
}

int main(int argc, char **argv)
{
	const char *image = NULL, *fstype = NULL, *phase = NULL;
	int c;
	while ((c = getopt(argc, argv, "d:t:p:")) != -1) {
		if (c == 'd') image = optarg;
		else if (c == 't') fstype = optarg;
		else if (c == 'p') phase = optarg;
	}
	if (!image || !fstype || !phase) {
		fprintf(stderr, "usage: gate0-rw -d IMAGE -t FSTYPE -p write|verify|verify-large|large-offset|raw-large|killed-mid-write|replay|umount-timeout|dirty-refused\n");
		return 2;
	}
	int ro = !strcmp(phase, "verify") || !strcmp(phase, "verify-large");

	struct lkl_disk disk = {0};
	/* read-write even to verify: xfs writes its log at mount, even a read-only one */
	disk.fd = open(image, O_RDWR);
	if (disk.fd < 0) { perror(image); return 1; }
	long r = lkl_init(&lkl_host_ops);
	tap(r == 0, "lkl_init", r);
	int id = lkl_disk_add(&disk);
	tap(id >= 0, "disk added", id);
	r = lkl_start_kernel("mem=128M");
	tap(r == 0, "kernel started", r);
	if (!strcmp(phase, "raw-large")) {
		phase_raw_large(id);
		lkl_sys_halt();
		lkl_disk_remove(disk);
		host_check_raw(disk.fd);
		close(disk.fd);
		lkl_cleanup();
		printf("1..%d\n", tapno);
		return failures ? 1 : 0;
	}
	if (!strcmp(phase, "dirty-refused")) {
		/* ntfs3 must refuse to mount a dirty volume read-write (no "force"). */
		r = lkl_mount_dev(id, 0, fstype, 0, NULL, mnt, sizeof(mnt));
		tap(r == -LKL_EINVAL, "read-write mount of the dirty volume refused", r);
		if (r == 0)
			lkl_umount_dev(id, 0, 0, 1000);
		lkl_sys_halt();
		lkl_disk_remove(disk);
		close(disk.fd);
		lkl_cleanup();
		printf("1..%d\n", tapno);
		return failures ? 1 : 0;
	}
	r = lkl_mount_dev(id, 0, fstype, ro ? LKL_MS_RDONLY : 0, NULL, mnt, sizeof(mnt));
	tap(r == 0, ro ? "mounted read-only" : "mounted read-write", r);
	if (r == 0) {
		if (!strcmp(phase, "write")) phase_write();
		else if (!strcmp(phase, "verify")) phase_verify();
		else if (!strcmp(phase, "verify-large")) phase_verify_large();
		else if (!strcmp(phase, "large-offset")) phase_large_offset();
		else if (!strcmp(phase, "killed-mid-write")) phase_churn();
		else if (!strcmp(phase, "replay")) ;
		else if (!strcmp(phase, "umount-timeout")) ;
		else { fprintf(stderr, "unknown phase %s\n", phase); return 2; }
		lkl_sys_chdir("/");
		if (!strcmp(phase, "umount-timeout")) {
			/* No time to wait for the teardown: it may time out, but must leave nothing behind. */
			struct lkl_stat st;
			struct __lkl__kernel_timespec ts = { 1, 0 };
			r = write_small(at("t"), "t");
			r = r ? r : lkl_umount_dev(id, 0, 0, 0);
			tap(r == 0 || r == -LKL_ETIMEDOUT, "unmount with no time to wait: done or timed out", r);
			r = lkl_sys_stat(mnt, &st);
			tap(r == -LKL_ENOENT, "mount point removed even so", r);
			lkl_sys_nanosleep(&ts, NULL);	/* the teardown finishes on its own */
		} else {
			r = lkl_umount_dev(id, 0, 0, 1000);
			tap(r == 0, "unmounted", r);
		}
	}
	lkl_sys_halt();
	lkl_disk_remove(disk);
	close(disk.fd);
	lkl_cleanup();
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
#ifdef __APPLE__
	ru.ru_maxrss /= 1024;	/* bytes on Darwin, KiB on Linux */
#endif
	printf("# maxrss %ld KiB\n", (long)ru.ru_maxrss);
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}

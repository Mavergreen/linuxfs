/*
 * lklfuse's callbacks, called directly (no FUSE mount) on an ext4 image, checking what the host's
 * FUSE layer would be told: host errno values, and host xattr/rename flags translated. On Darwin
 * these differ from Linux's numbers, which LKL returns. Built with lklfuse.c itself included.
 * usage: lklfuse-ops-test EXT4-IMAGE
 */
#define main lklfuse_main
#include "lklfuse.c"
#undef main
#include <sys/xattr.h>
#include <limits.h>

static int tapno, failures;


static void is(int got, int want, const char *what)
{
	tapno++;
	if (got == want) {
		printf("ok %d - %s\n", tapno, what);
	} else {
		printf("not ok %d - %s (got %d, want %d)\n", tapno, what, got, want);
		failures++;
	}
}

static int owner_of(const char *path, uid_t *uid, gid_t *gid)
{
	struct stat st;
	int ret = lklfuse_getattr(path, &st, NULL);

	*uid = st.st_uid;
	*gid = st.st_gid;
	return ret;
}

static void owned(const char *path, uid_t uid, gid_t gid, const char *what)
{
	uid_t u = 99999;
	gid_t g = 99999;

	owner_of(path, &u, &g);
	is((int)u, (int)uid, what);
	is((int)g, (int)gid, what);
}

#ifdef ENOATTR
#define HOST_ENOATTR ENOATTR	/* Darwin's "no such xattr" */
#else
#define HOST_ENOATTR ENODATA	/* Linux's */
#endif

int main(int argc, char **argv)
{
	char longname[NAME_MAX + 8];
	struct fuse_file_info fi = { .flags = O_WRONLY };

	if (argc != 2) {
		fprintf(stderr, "usage: lklfuse-ops-test EXT4-IMAGE\n");
		return 2;
	}
	lklfuse.file = argv[1];
	lklfuse.type = "ext4";
	lklfuse.disk.fd = lklfuse_open_disk();
	if (lklfuse.disk.fd < 0 || lkl_init(&lkl_host_ops) < 0)
		return 1;
	lklfuse.disk_id = lkl_disk_add(&lklfuse.disk);
	if (lklfuse.disk_id < 0 || start_lkl())
		return 1;

	is(!!(fcntl(lklfuse.disk.fd, F_GETFD) & FD_CLOEXEC), 1, "the image is opened close-on-exec, so mount helpers do not inherit it");
	is(lklfuse_getattr("/missing", &(struct stat){ 0 }, NULL), -ENOENT, "getattr on a missing file: ENOENT");
	is(lklfuse_getxattr("/", "user.none", NULL, 0), -HOST_ENOATTR, "getxattr of a missing xattr: ENOATTR");
	is(lklfuse_setxattr("/", "com.apple.FinderInfo", "x", 1, 0), -ENOTSUP,
	   "setxattr outside Linux's namespaces: ENOTSUP, so macFUSE can fall back");
	is(lklfuse_setxattr("/", "user.a", "1", 1, XATTR_CREATE), 0, "setxattr XATTR_CREATE of a new xattr");
	is(lklfuse_setxattr("/", "user.a", "1", 1, XATTR_CREATE), -EEXIST, "setxattr XATTR_CREATE of an existing one: EEXIST");
	is(lklfuse_setxattr("/", "user.a", "2", 1, XATTR_REPLACE), 0, "setxattr XATTR_REPLACE of an existing xattr");
	is(lklfuse_setxattr("/", "user.b", "2", 1, XATTR_REPLACE), -HOST_ENOATTR,
	   "setxattr XATTR_REPLACE of a missing one: ENOATTR");
	is(lklfuse_mkdir("/d", 0755), 0, "mkdir");
	is(lklfuse_create("/d/f", 0644, &fi), 0, "create");
	is(lklfuse_write("/d/f", "hello", 5, 0, &fi), 5, "write returns the byte count");
	is(lklfuse_release("/d/f", &fi), 0, "release");
	is(lklfuse_rmdir("/d"), -ENOTEMPTY, "rmdir of a non-empty directory: ENOTEMPTY");
	memset(longname, 'n', sizeof(longname) - 1);
	longname[0] = '/';
	longname[sizeof(longname) - 1] = '\0';
	is(lklfuse_mkdir(longname, 0755), -ENAMETOOLONG, "mkdir of an over-long name: ENAMETOOLONG");
	is(lklfuse_mkdir("/e", 0755), 0, "mkdir another");
#ifdef RENAME_EXCL
	is(lklfuse_rename("/e", "/d", RENAME_EXCL), -EEXIST, "rename RENAME_EXCL onto an existing name: EEXIST");
#else
	is(lklfuse_rename("/e", "/d", RENAME_NOREPLACE), -EEXIST, "rename RENAME_NOREPLACE onto an existing name: EEXIST");
#endif
	/* New files' owner: none by default, the filesystem root's with owner=root, or uid:gid. */
	is(lklfuse_mkdir("/o0", 0755), 0, "mkdir without owner=");
	owned("/o0", 0, 0, "without owner=, a new directory keeps LKL's own ids (0:0)");
	is(lklfuse_err(lkl_sys_fchownat(LKL_AT_FDCWD, "/", 1234, 5678, 0)), 0, "chown the root to 1234:5678");
	lklfuse.owner = "root";
	is(lklfuse_set_owner(), 0, "owner=root takes the root's ids");
	is(lklfuse_mkdir("/o1", 0755), 0, "mkdir with owner=root");
	owned("/o1", 1234, 5678, "owner=root: a new directory is the root's");
	fi.flags = O_WRONLY;
	is(lklfuse_create("/o1/f", 0644, &fi), 0, "create with owner=root");
	lklfuse_release("/o1/f", &fi);
	owned("/o1/f", 1234, 5678, "owner=root: a new file is the root's");
	is(lklfuse_symlink("f", "/o1/l"), 0, "symlink with owner=root");
	owned("/o1/l", 1234, 5678, "owner=root: a new symlink itself is the root's");
	is(lklfuse_mknod("/o1/p", S_IFIFO | 0644, 0), 0, "mknod with owner=root");
	owned("/o1/p", 1234, 5678, "owner=root: a new fifo is the root's");
	owned("/d/f", 0, 0, "a file made before owner= keeps its owner");
	fi.flags = O_WRONLY;
	is(lklfuse_create("/d/f", 0644, &fi), 0, "create of an existing file");
	lklfuse_release("/d/f", &fi);
	owned("/d/f", 0, 0, "create of an existing file does not change its owner");
	/* review M4: when O_EXCL finds a name but a plain open does not (unlinked meanwhile; here, a dangling
	 * symlink, which shows it every time), the file create then makes must still take owner= */
	is(lklfuse_symlink("made", "/o1/dangle"), 0, "a dangling symlink");
	fi.flags = O_WRONLY;
	is(lklfuse_create("/o1/dangle", 0644, &fi), 0, "create through a dangling symlink");
	lklfuse_release("/o1/dangle", &fi);
	owned("/o1/made", 1234, 5678, "the file it made takes owner= (M4)");
	lklfuse.owner = "42:43";
	is(lklfuse_set_owner(), 0, "owner=42:43");
	is(lklfuse_mkdir("/o2", 0755), 0, "mkdir with owner=42:43");
	owned("/o2", 42, 43, "owner=42:43: a new directory is 42:43");
	lklfuse.owner = "nobody";
	is(lklfuse_set_owner() < 0, 1, "owner= that is neither root nor uid:gid is refused");
	{
		/* linuxfs-open hands lklfuse the helper's descriptor as /dev/fd/3 */
		char path[32];
		const char *file = lklfuse.file;
		int n = open(argv[1], O_RDONLY);

		snprintf(path, sizeof(path), "/dev/fd/%d", n);
		lklfuse.file = path;
		is(lklfuse_open_disk(), n, "/dev/fd/N is used as descriptor N itself");
		is(!!(fcntl(n, F_GETFD) & FD_CLOEXEC), 1, "and is made close-on-exec");
		lklfuse.file = file;
		close(n);
	}
	stop_lkl();
	lkl_cleanup();
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}

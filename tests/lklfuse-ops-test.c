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

#ifdef __APPLE__
/*
 * Darwin Unicode names (patch 0012): stored NFC, shown as HFS+ shows them (NFD), found by any form. The conversions
 * use CoreFoundation, so these run on the Mac only. Names are planted with lkl_sys_* and read back with getdents64,
 * so what is on disk is seen as Linux sees it.
 */
#define NFC_CAFE "caf\xc3\xa9"
#define NFD_CAFE "cafe\xcc\x81"

static void is_str(const char *got, const char *want, const char *what)
{
	tapno++;
	if (got && strcmp(got, want) == 0) {
		printf("ok %d - %s\n", tapno, what);
	} else {
		printf("not ok %d - %s (got %s)\n", tapno, what, got ? got : "NULL");
		failures++;
	}
}

typedef const char *(*nf_conv)(const char *in, char *buf, size_t len);

/* want NULL: the conversion hands back the input itself */
static void conv(nf_conv f, const char *in, const char *want, size_t len, const char *what)
{
	char buf[PATH_MAX];
	const char *got = f(in, buf, len);

	if (want)
		is_str(got, want, what);
	else
		is(got == in, 1, what);
}

/* entries of DIR, as Linux reads them: those named WANT, or all but . and .. when WANT is NULL */
static int names_in(const char *dir, const char *want)
{
	char b[4096];
	long fd = lkl_sys_open(dir, LKL_O_RDONLY | LKL_O_DIRECTORY, 0), n, off;
	int count = 0;

	if (fd < 0)
		return -1;
	while ((n = lkl_sys_getdents64(fd, (void *)b, sizeof(b))) > 0) {
		for (off = 0; off < n; ) {
			struct lkl_linux_dirent64 *de = (void *)(b + off);

			off += de->d_reclen;
			if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
				continue;
			if (!want || strcmp(de->d_name, want) == 0)
				count++;
		}
	}
	lkl_sys_close(fd);
	return count;
}

static void plant(const char *path, const char *content)
{
	long fd = lkl_sys_open(path, LKL_O_WRONLY | LKL_O_CREAT | LKL_O_TRUNC, 0644);

	if (fd >= 0) {
		lkl_sys_write(fd, content, strlen(content));
		lkl_sys_close(fd);
	}
}

static int opens(const char *path)
{
	struct fuse_file_info f = { .flags = O_RDONLY };
	int ret = lklfuse_open(path, &f);

	if (ret == 0)
		lklfuse_release(path, &f);
	return ret;
}

static const char *content_of(const char *path, char *buf, size_t len)
{
	struct fuse_file_info f = { .flags = O_RDONLY };
	int n;

	if (lklfuse_open(path, &f))
		return NULL;
	n = lklfuse_read(path, buf, len - 1, 0, &f);
	lklfuse_release(path, &f);
	if (n < 0)
		return NULL;
	buf[n] = '\0';
	return buf;
}

struct seen {
	int n;
	char names[8][NAME_MAX + 1];
};

static int seen_fill(void *buf, const char *name, const struct stat *st, off_t off, enum fuse_fill_dir_flags flags)
{
	struct seen *s = buf;

	if (strcmp(name, ".") && strcmp(name, "..") && s->n < 8)
		snprintf(s->names[s->n++], sizeof(s->names[0]), "%s", name);
	return 0;
}

static int readdir_of(const char *path, struct seen *s)
{
	struct fuse_file_info f = { 0 };
	int ret;

	memset(s, 0, sizeof(*s));
	if ((ret = lklfuse_opendir(path, &f)))
		return ret;
	ret = lklfuse_readdir(path, s, seen_fill, 0, &f, 0);
	lklfuse_releasedir(path, &f);
	return ret;
}

static void unicode_tests(void)
{
	struct fuse_file_info f;
	struct stat st;
	struct seen s;
	char buf[PATH_MAX], name[PATH_MAX];
	unsigned long scans;
	int i;

	/* the modes */
	is(lklfuse_nfmode_for("ext4"), NF_STORE_NFC, "ext4 stores NFC");
	is(lklfuse_nfmode_for("ext2"), NF_STORE_NFC, "ext2 stores NFC");
	is(lklfuse_nfmode_for("ext3"), NF_STORE_NFC, "ext3 stores NFC");
	is(lklfuse_nfmode_for("btrfs"), NF_STORE_NFC, "btrfs stores NFC");
	is(lklfuse_nfmode_for("xfs"), NF_STORE_NFC, "xfs stores NFC");
	is(lklfuse_nfmode_for("f2fs"), NF_STORE_NFC, "f2fs stores NFC");
	is(lklfuse_nfmode_for("ntfs3"), NF_STORE_NFC, "ntfs3 stores NFC");
	is(lklfuse_nfmode_for("apfs"), NF_AS_GIVEN, "apfs stores names as given");
	is(lklfuse_nfmode_for("vfat"), NF_OFF, "vfat: off (Task 7)");
	is(lklfuse_nfmode_for("exfat"), NF_OFF, "exfat: off (Task 7)");
	is(lklfuse_nf, NF_STORE_NFC, "the ext4 mount stores NFC");

	/* the conversions */
	conv(lklfuse_nfc, "plain.txt", NULL, PATH_MAX, "NFC of ASCII is the input itself");
	conv(lklfuse_nfd_hfs, "plain.txt", NULL, PATH_MAX, "NFD of ASCII is the input itself");
	conv(lklfuse_nfc, NFD_CAFE, NFC_CAFE, PATH_MAX, "NFC of NFD cafe");
	conv(lklfuse_nfd_hfs, NFC_CAFE, NFD_CAFE, PATH_MAX, "NFD of NFC cafe");
	conv(lklfuse_nfc, NFC_CAFE, NULL, PATH_MAX, "NFC of NFC is the input itself");
	conv(lklfuse_nfd_hfs, NFD_CAFE, NULL, PATH_MAX, "NFD of NFD is the input itself");
	conv(lklfuse_nfd_hfs, "\xed\x95\x9c", "\xe1\x84\x92\xe1\x85\xa1\xe1\x86\xab", PATH_MAX, "NFD of Hangul");
	conv(lklfuse_nfc, "\xe1\x84\x92\xe1\x85\xa1\xe1\x86\xab", "\xed\x95\x9c", PATH_MAX, "NFC of Hangul jamo");
	conv(lklfuse_nfd_hfs, "\xe2\x84\xa6", NULL, PATH_MAX, "HFS+ NFD leaves U+2126 (U+2000-U+2FFF)");
	conv(lklfuse_nfd_hfs, "\xef\xa4\x80", NULL, PATH_MAX, "HFS+ NFD leaves U+F900 (U+F900-U+FAFF)");
	conv(lklfuse_nfd_hfs, "\xf0\xaf\xa0\x80", NULL, PATH_MAX, "HFS+ NFD leaves U+2F800 (U+2F800-U+2FAFF)");
	conv(lklfuse_nfd_hfs, NFC_CAFE "\xf0\xaf\xa0\x80\xc3\xa9", NFD_CAFE "\xf0\xaf\xa0\x80" "e\xcc\x81", PATH_MAX,
	     "HFS+ NFD decomposes around a kept U+2F800");
	/* controller ruling (fix round 1): NFC keeps HFS+'s excluded ranges too, so singletons are stored as given */
	conv(lklfuse_nfc, "\xe2\x84\xa6", NULL, PATH_MAX, "NFC leaves U+2126 (OHM SIGN) as given");
	conv(lklfuse_nfc, "\xe2\x84\xab", NULL, PATH_MAX, "NFC leaves U+212B (ANGSTROM SIGN) as given");
	conv(lklfuse_nfc, "\xef\xa4\x80", NULL, PATH_MAX, "NFC leaves U+F900 as given");
	conv(lklfuse_nfc, "\xf0\xaf\xa0\x80", NULL, PATH_MAX, "NFC leaves U+2F800 as given");
	conv(lklfuse_nfc, NFD_CAFE "\xe2\x84\xab" "e\xcc\x81", NFC_CAFE "\xe2\x84\xab\xc3\xa9", PATH_MAX,
	     "NFC composes around a kept U+212B");
	conv(lklfuse_nfd_hfs, "\xe2\x84\xab", NULL, PATH_MAX, "HFS+ NFD leaves U+212B");
	/* review I1: CoreFoundation drops a leading U+FEFF; the conversions keep it */
	conv(lklfuse_nfc, "\xef\xbb\xbf" NFD_CAFE, "\xef\xbb\xbf" NFC_CAFE, PATH_MAX, "NFC keeps a leading U+FEFF");
	conv(lklfuse_nfd_hfs, "\xef\xbb\xbf" NFC_CAFE, "\xef\xbb\xbf" NFD_CAFE, PATH_MAX, "NFD keeps a leading U+FEFF");
	conv(lklfuse_nfc, "\xef\xbb\xbf" "abc", NULL, PATH_MAX, "NFC of U+FEFF abc is the input itself");
	conv(lklfuse_nfd_hfs, "\xef\xbb\xbf" "abc", NULL, PATH_MAX, "NFD of U+FEFF abc is the input itself");
	conv(lklfuse_nfc, "\xff\xfe", NULL, PATH_MAX, "NFC of invalid UTF-8 is the input itself");
	conv(lklfuse_nfd_hfs, "\xff\xfe", NULL, PATH_MAX, "NFD of invalid UTF-8 is the input itself");
	conv(lklfuse_nfc, "/e\xcc\x81/" NFD_CAFE, "/\xc3\xa9/" NFC_CAFE, PATH_MAX, "NFC of a whole path");
	is(lklfuse_nfc(NFD_CAFE, buf, 4) == NULL, 1, "NFC into a 4-byte buffer: NULL");
	is(lklfuse_nfd_hfs(NFC_CAFE, buf, 4) == NULL, 1, "NFD into a 4-byte buffer: NULL");

	/* create_nfd_lands_nfc */
	is(lklfuse_mkdir("/u1", 0755), 0, "mkdir /u1");
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create("/u1/" NFD_CAFE, 0644, &f), 0, "create_nfd_lands_nfc: create by NFD");
	lklfuse_write("/u1/" NFD_CAFE, "one", 3, 0, &f);
	lklfuse_release("/u1/" NFD_CAFE, &f);
	is(names_in("/u1", NFC_CAFE), 1, "create_nfd_lands_nfc: on disk as NFC");
	is(names_in("/u1", NULL), 1, "create_nfd_lands_nfc: and only that");

	/* open_both_forms */
	is(lklfuse_getattr("/u1/" NFC_CAFE, &st, NULL), 0, "open_both_forms: getattr by NFC");
	is(lklfuse_getattr("/u1/" NFD_CAFE, &st, NULL), 0, "open_both_forms: getattr by NFD");
	is(opens("/u1/" NFC_CAFE), 0, "open_both_forms: open by NFC");
	is(opens("/u1/" NFD_CAFE), 0, "open_both_forms: open by NFD");

	/*
	 * enxio_sequence (census, push A): macFUSE's libfuse creates with the name as the kernel gave it (NFC), then
	 * names the node NFD in its table, so every later call on it (getattr, open) comes with an NFD path. Without the
	 * resolver that getattr was ENOENT on the NFC file just created, and the create failed with ENXIO.
	 */
	is(lklfuse_mkdir("/u2", 0755), 0, "mkdir /u2");
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create("/u2/" NFC_CAFE, 0644, &f), 0, "enxio_sequence: create by NFC");
	lklfuse_release("/u2/" NFC_CAFE, &f);
	is(names_in("/u2", NFC_CAFE), 1, "enxio_sequence: on disk as NFC");
	is(lklfuse_getattr("/u2/" NFD_CAFE, &st, NULL), 0, "enxio_sequence: getattr by libfuse's NFD path");
	is(opens("/u2/" NFD_CAFE), 0, "enxio_sequence: open by libfuse's NFD path");
	is(lklfuse_access("/u2/" NFD_CAFE, R_OK), 0, "enxio_sequence: access by libfuse's NFD path");

	/* ondisk_nfd_kept */
	is(lkl_sys_mkdir("/u3", 0755), 0, "mkdir /u3");
	plant("/u3/nai\xcc\x88ve", "naive");
	is(opens("/u3/na\xc3\xafve"), 0, "ondisk_nfd_kept: opens by NFC");
	is(opens("/u3/nai\xcc\x88ve"), 0, "ondisk_nfd_kept: opens by NFD");
	is(names_in("/u3", "nai\xcc\x88ve"), 1, "ondisk_nfd_kept: still NFD on disk");
	is(names_in("/u3", NULL), 1, "ondisk_nfd_kept: and nothing else");

	/* create_existing_nfd */
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create("/u3/na\xc3\xafve", 0644, &f), 0, "create_existing_nfd: create by NFC opens the NFD file");
	lklfuse_release("/u3/na\xc3\xafve", &f);
	is(names_in("/u3", NULL), 1, "create_existing_nfd: one entry");
	is(names_in("/u3", "nai\xcc\x88ve"), 1, "create_existing_nfd: the NFD one");
	f = (struct fuse_file_info){ .flags = O_WRONLY | O_EXCL };
	is(lklfuse_create("/u3/na\xc3\xafve", 0644, &f), -EEXIST, "create_existing_nfd: O_EXCL: EEXIST");

	/* rename_replaces */
	plant("/u3/x", "from x");
	is(lklfuse_rename("/u3/x", "/u3/na\xc3\xafve", 0), 0, "rename_replaces: rename onto the NFC spelling");
	is(names_in("/u3", NULL), 1, "rename_replaces: one entry");
	is_str(content_of("/u3/nai\xcc\x88ve", buf, sizeof(buf)), "from x", "rename_replaces: holding x's content");

	/* readdir_nfd */
	is(lkl_sys_mkdir("/u4", 0755), 0, "mkdir /u4");
	plant("/u4/" NFC_CAFE, "");
	is(readdir_of("/u4", &s), 0, "readdir_nfd: readdir");
	is(s.n, 1, "readdir_nfd: one entry");
	is_str(s.names[0], NFD_CAFE, "readdir_nfd: handed out NFD");

	/* intermediate */
	is(lkl_sys_mkdir("/\xc3\xa9", 0755), 0, "mkdir an NFC directory");
	plant("/\xc3\xa9/f", "deep");
	is(lklfuse_getattr("/e\xcc\x81/f", &st, NULL), 0, "intermediate: getattr under the NFD spelling");
	is_str(content_of("/e\xcc\x81/f", buf, sizeof(buf)), "deep", "intermediate: opens under the NFD spelling");

	/* neither_form_scan: a, U+0301, U+0323 is neither NFC (U+1EA1 U+0301) nor NFD (a U+0323 U+0301) */
	is(lkl_sys_mkdir("/u5", 0755), 0, "mkdir /u5");
	plant("/u5/a\xcc\x81\xcc\xa3", "odd");
	scans = lklfuse_nf_scans;
	is_str(content_of("/u5/\xe1\xba\xa1\xcc\x81", buf, sizeof(buf)), "odd", "neither_form_scan: opens by its NFC form");
	is((int)(lklfuse_nf_scans - scans), 1, "neither_form_scan: lklfuse_nf_scans grows by 1 (open)");
	scans = lklfuse_nf_scans;
	is(lklfuse_getattr("/u5/\xe1\xba\xa1\xcc\x81", &st, NULL), 0, "neither_form_scan: getattr by its NFC form");
	is((int)(lklfuse_nf_scans - scans), 1, "neither_form_scan: lklfuse_nf_scans grows by 1");

	/* ascii_miss_no_scan */
	scans = lklfuse_nf_scans;
	is(lklfuse_getattr("/missing", &st, NULL), -ENOENT, "ascii_miss_no_scan: ENOENT");
	is(lklfuse_getattr("/u5/missing", &st, NULL), -ENOENT, "ascii_miss_no_scan: ENOENT in a directory");
	is((int)(lklfuse_nf_scans - scans), 0, "ascii_miss_no_scan: no scan");

	/* symlink_target_nfc */
	is(lklfuse_symlink(NFD_CAFE, "/l"), 0, "symlink_target_nfc: symlink");
	memset(name, 0, sizeof(name));
	lkl_sys_readlink("/l", name, sizeof(name) - 1);
	is_str(name, NFC_CAFE, "symlink_target_nfc: the target is stored NFC");
	is(lklfuse_readlink("/l", buf, sizeof(buf)), 0, "symlink_target_nfc: readlink");
	is_str(buf, NFD_CAFE, "symlink_target_nfc: readlink hands out NFD");

	/* apfs_as_given */
	lklfuse_nf = NF_AS_GIVEN;
	is(lkl_sys_mkdir("/u6", 0755), 0, "mkdir /u6");
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create("/u6/" NFD_CAFE, 0644, &f), 0, "apfs_as_given: create by NFD");
	lklfuse_release("/u6/" NFD_CAFE, &f);
	is(names_in("/u6", NFD_CAFE), 1, "apfs_as_given: stored as given (NFD)");
	is(opens("/u6/" NFC_CAFE), 0, "apfs_as_given: opens by NFC");
	lklfuse_nf = NF_STORE_NFC;

	/* pair_* (Review Focus 1): both forms on disk, as Linux can make them */
	is(lkl_sys_mkdir("/pair", 0755), 0, "mkdir /pair");
	plant("/pair/" NFC_CAFE, "nfc");
	plant("/pair/" NFD_CAFE, "nfd");
	is(readdir_of("/pair", &s), 0, "pair_readdir: readdir");
	is(s.n, 2, "pair_readdir: two entries");
	is(lklfuse_unlink("/pair/" NFD_CAFE), 0, "pair_unlink: unlink by the NFD spelling");
	is(names_in("/pair", NFC_CAFE), 0, "pair_unlink: removed the NFC entry");
	is(names_in("/pair", NFD_CAFE), 1, "pair_unlink: kept the NFD entry");
	is_str(content_of("/pair/" NFC_CAFE, buf, sizeof(buf)), "nfd", "pair_left: opens by NFC, its content unchanged");
	is_str(content_of("/pair/" NFD_CAFE, buf, sizeof(buf)), "nfd", "pair_left: opens by NFD, its content unchanged");

	/* nfd_overlong_* (Review Focus 2): 250 bytes NFC is 375 bytes NFD, over NAME_MAX */
	is(lklfuse_mkdir("/u7", 0755), 0, "mkdir /u7");
	strcpy(name, "/u7/");
	for (i = 0; i < 125; i++)
		strcat(name, "\xc3\xa9");
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create(name, 0644, &f), 0, "nfd_overlong_create: a 250-byte NFC name");
	lklfuse_release(name, &f);
	is(readdir_of("/u7", &s), 0, "nfd_overlong_readdir: readdir");
	is_str(s.names[0], name + 4, "nfd_overlong_readdir: handed out as stored");
	is(opens(name), 0, "nfd_overlong_open: opens");
	strcpy(buf, "/u7/");
	for (i = 0; i < 125; i++)
		strcat(buf, "e\xcc\x81");
	is(opens(buf), 0, "nfd_overlong_open: opens by libfuse's NFD path too");

	/* the other path-taking callbacks resolve too */
	is(lklfuse_chmod("/u1/" NFD_CAFE, 0600, NULL), 0, "chmod by NFD");
	is(lklfuse_utimens("/u1/" NFD_CAFE, (struct timespec[2]){ { 0, 0 }, { 0, 0 } }, NULL), 0, "utimens by NFD");
	is(lklfuse_truncate("/u1/" NFD_CAFE, 0, NULL), 0, "truncate by NFD");
	is(lklfuse_setxattr("/u1/" NFD_CAFE, "user.u", "1", 1, 0), 0, "setxattr by NFD");
	is(lklfuse_getxattr("/u1/" NFD_CAFE, "user.u", buf, sizeof(buf)), 1, "getxattr by NFD");
	is(lklfuse_listxattr("/u1/" NFD_CAFE, buf, sizeof(buf)) > 0, 1, "listxattr by NFD");
	is(lklfuse_removexattr("/u1/" NFD_CAFE, "user.u"), 0, "removexattr by NFD");
	is(lklfuse_link("/u1/" NFD_CAFE, "/u1/h" NFD_CAFE), 0, "link by NFD, to an NFD name");
	is(names_in("/u1", "h" NFC_CAFE), 1, "link: the new name lands NFC");
	is(lklfuse_mkdir("/u1/d" NFD_CAFE, 0755), 0, "mkdir by NFD");
	is(names_in("/u1", "d" NFC_CAFE), 1, "mkdir: lands NFC");
	is(lklfuse_rmdir("/u1/d" NFD_CAFE), 0, "rmdir by NFD");
	is(lklfuse_mknod("/u1/p" NFD_CAFE, S_IFIFO | 0644, 0), 0, "mknod by NFD");
	is(names_in("/u1", "p" NFC_CAFE), 1, "mknod: lands NFC");
	is(lklfuse_chown("/u1/p" NFD_CAFE, 7, 8, NULL), 0, "chown by NFD");
	is(lklfuse_statfs("/u1/p" NFD_CAFE, &(struct statvfs){ 0 }), 0, "statfs by NFD");
	is(lklfuse_unlink("/u1/p" NFD_CAFE), 0, "unlink by NFD");
	is(lklfuse_rename("/u1/h" NFD_CAFE, "/u1/r" NFD_CAFE, 0), 0, "rename by NFD");
	is(names_in("/u1", "r" NFC_CAFE), 1, "rename: the new name lands NFC");
	is(names_in("/u1", NULL), 2, "rename: the old name is gone");

	/* review M2: opendir, readlink and symlink's link path by non-ASCII paths */
	is(readdir_of("/e\xcc\x81", &s), 0, "opendir by an NFD path");
	is(s.n == 1 && strcmp(s.names[0], "f") == 0, 1, "and readdir lists the NFC directory");
	is(lkl_sys_mkdir("/u8", 0755), 0, "mkdir /u8");
	is(lklfuse_symlink("x", "/u8/l" NFD_CAFE), 0, "symlink with an NFD link path");
	is(names_in("/u8", "l" NFC_CAFE), 1, "symlink: the link lands NFC");
	is(lklfuse_readlink("/u8/l" NFD_CAFE, buf, sizeof(buf)), 0, "readlink by an NFD path");
	is_str(buf, "x", "readlink by an NFD path: the target");

	/* review I1: a U+FEFF-led name is its own name, never its sibling without the U+FEFF */
	is(lkl_sys_mkdir("/b", 0755), 0, "mkdir /b");
	plant("/b/\xef\xbb\xbf\xc3\xa9", "bom");
	plant("/b/\xc3\xa9", "plain");
	is(readdir_of("/b", &s), 0, "bom: readdir");
	is(s.n == 2 && (strcmp(s.names[0], "\xef\xbb\xbf" "e\xcc\x81") == 0 ||
			strcmp(s.names[1], "\xef\xbb\xbf" "e\xcc\x81") == 0), 1, "bom: readdir shows the U+FEFF");
	is_str(content_of("/b/\xef\xbb\xbf" "e\xcc\x81", buf, sizeof(buf)), "bom", "bom: opens its own file by NFD");
	is(lklfuse_unlink("/b/\xef\xbb\xbf" "e\xcc\x81"), 0, "bom: unlink by the U+FEFF name");
	is(names_in("/b", "\xc3\xa9"), 1, "bom: the sibling is left");
	is(names_in("/b", NULL), 1, "bom: and only the sibling");
	is_str(content_of("/b/\xc3\xa9", buf, sizeof(buf)), "plain", "bom: the sibling's content unchanged");
	f = (struct fuse_file_info){ .flags = O_WRONLY | O_EXCL };
	is(lklfuse_create("/b/\xef\xbb\xbf" "e\xcc\x81", 0644, &f), 0, "bom: O_EXCL create beside the sibling");
	lklfuse_release("/b/\xef\xbb\xbf" "e\xcc\x81", &f);
	is(names_in("/b", "\xef\xbb\xbf\xc3\xa9"), 1, "bom: create keeps the U+FEFF (and stores NFC)");
	is(names_in("/b", NULL), 2, "bom: two entries");

	/* controller ruling: singletons are stored as given, and still found by libfuse's ICU NFD spelling */
	is(lkl_sys_mkdir("/u9", 0755), 0, "mkdir /u9");
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create("/u9/\xe2\x84\xa6", 0644, &f), 0, "create U+2126");
	lklfuse_release("/u9/\xe2\x84\xa6", &f);
	is(names_in("/u9", "\xe2\x84\xa6"), 1, "U+2126 is stored as given");
	is(opens("/u9/\xce\xa9"), 0, "and opens by U+03A9 (libfuse's ICU NFD of it)");
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create("/u9/\xe2\x84\xab", 0644, &f), 0, "create U+212B");
	lklfuse_release("/u9/\xe2\x84\xab", &f);
	is(names_in("/u9", "\xe2\x84\xab"), 1, "U+212B is stored as given");
	is(opens("/u9/A\xcc\x8a"), 0, "and opens by A U+030A (libfuse's ICU NFD of it)");
	is(opens("/u9/\xc3\x85"), 0, "and by U+00C5");

	/* review M1: a non-ASCII path over Darwin's PATH_MAX (1024), within LKL's (4096) */
	{
		char nfcp[4096] = "", nfdp[4096] = "", comp[256];
		int d;

		comp[0] = '\0';
		for (i = 0; i < 100; i++)
			strcat(comp, "\xc3\xa9");
		for (d = 0; d < 6; d++) {
			strcat(nfcp, "/");
			strcat(nfcp, comp);
			lkl_sys_mkdir(nfcp, 0755);
			strcat(nfdp, "/");
			for (i = 0; i < 100; i++)
				strcat(nfdp, "e\xcc\x81");
		}
		is(strlen(nfcp) > 1024 && strlen(nfdp) > 1024, 1, "long_path: both spellings are over 1024 bytes");
		is(lklfuse_getattr(nfdp, &st, NULL), 0, "long_path: getattr by the NFD spelling");
		strcat(nfdp, "/f");
		f = (struct fuse_file_info){ .flags = O_WRONLY };
		is(lklfuse_create(nfdp, 0644, &f), 0, "long_path: create under it");
		lklfuse_release(nfdp, &f);
		strcat(nfcp, "/f");
		is(lkl_sys_access(nfcp, 0), 0, "long_path: it lands under the NFC directories");
	}
}
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
#ifdef __APPLE__
	unicode_tests();
#endif
	stop_lkl();
	lkl_cleanup();
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}

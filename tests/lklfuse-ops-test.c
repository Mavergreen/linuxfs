/*
 * lklfuse's callbacks, called directly (no FUSE mount) on an ext4 image, checking what the host's
 * FUSE layer would be told: host errno values, and host xattr/rename flags translated. On Darwin
 * these differ from Linux's numbers, which LKL returns. Built with lklfuse.c itself included.
 * usage: lklfuse-ops-test EXT4-IMAGE
 */
#define main lklfuse_main
#define fuse_get_context test_fuse_get_context	/* the FUSE caller, which a test sets (owner=caller) */
#include "lklfuse.c"
#undef fuse_get_context
#undef main
#include <sys/xattr.h>
#include <limits.h>

static int tapno, failures;
static const char *tap_tag = "";	/* before each description: the resolver mode a test runs in */

static void is(int got, int want, const char *what)
{
	tapno++;
	if (got == want) {
		printf("ok %d - %s%s\n", tapno, tap_tag, what);
	} else {
		printf("not ok %d - %s%s (got %d, want %d)\n", tapno, tap_tag, what, got, want);
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

/* no FUSE request here: the caller is whatever the test says, or none */
static struct fuse_context test_ctx;
static int test_ctx_set;

struct fuse_context *test_fuse_get_context(void)
{
	return test_ctx_set ? &test_ctx : NULL;
}

#ifdef ENOATTR
#define HOST_ENOATTR ENOATTR	/* Darwin's "no such xattr" */
#else
#define HOST_ENOATTR ENODATA	/* Linux's */
#endif

#ifdef __APPLE__
/*
 * Darwin Unicode names (patch 0012): stored NFC, shown as HFS+ shows them (NFD), found by any form, in both modes:
 * scanning (an older macFUSE) and exact (5.5.0-mavericks.5's -o nonorm_insensitive, never a scan). The conversions
 * use CoreFoundation, so these run on the Mac only. Names are planted with lkl_sys_* and read back with getdents64,
 * so what is on disk is seen as Linux sees it.
 */
#define NFC_CAFE "caf\xc3\xa9"
#define NFD_CAFE "cafe\xcc\x81"

static void is_str(const char *got, const char *want, const char *what)
{
	tapno++;
	if (got && strcmp(got, want) == 0) {
		printf("ok %d - %s%s\n", tapno, tap_tag, what);
	} else {
		printf("not ok %d - %s%s (got %s)\n", tapno, tap_tag, what, got ? got : "NULL");
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

static void unicode_conv_tests(void)
{
	char buf[PATH_MAX];

	/* the modes */
	is(lklfuse_nfmode_for("ext4"), NF_STORE_NFC, "ext4 stores NFC");
	is(lklfuse_nfmode_for("ext2"), NF_STORE_NFC, "ext2 stores NFC");
	is(lklfuse_nfmode_for("ext3"), NF_STORE_NFC, "ext3 stores NFC");
	is(lklfuse_nfmode_for("btrfs"), NF_STORE_NFC, "btrfs stores NFC");
	is(lklfuse_nfmode_for("xfs"), NF_STORE_NFC, "xfs stores NFC");
	is(lklfuse_nfmode_for("f2fs"), NF_STORE_NFC, "f2fs stores NFC");
	is(lklfuse_nfmode_for("ntfs3"), NF_STORE_NFC, "ntfs3 stores NFC");
	is(lklfuse_nfmode_for("apfs"), NF_AS_GIVEN, "apfs stores names as given");
	/* vfat_mode_nfc: `linuxfs mount` mounts FAT and exFAT images, which take the form Apple's msdosfs writes (NFC;
	 * the census's FAT32 control checks it, item-1-findings.md) */
	is(lklfuse_nfmode_for("vfat"), NF_STORE_NFC, "vfat_mode_nfc: vfat stores NFC, as Apple's msdosfs does");
	is(lklfuse_nfmode_for("exfat"), NF_STORE_NFC, "vfat_mode_nfc: exfat stores NFC, as Apple's msdosfs does");
	is(lklfuse_nfmode_for("msdos"), NF_OFF, "a type with no mode: off");
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
	/* review N1: a kept character is not composed with the mark after it (full NFC would give U+219A) */
	conv(lklfuse_nfc, "\xe2\x86\x90\xcc\xb8", NULL, PATH_MAX, "NFC leaves U+2190 U+0338 as given");
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
}

/*
 * Each resolver case, in one mode: scanning (an older macFUSE, whose libfuse spells every path but a new entry's by
 * ICU's NFD) or exact (macFUSE's -o nonorm_insensitive: the kernel's bytes, lookups only, never a scan). Run in a
 * directory of its own, made the root.
 */
static void resolver_tests(int exact)
{
	struct fuse_file_info f;
	struct stat st;
	struct seen s;
	char buf[PATH_MAX], name[PATH_MAX];
	unsigned long scans, scans0 = lklfuse_nf_scans;
	/* the path libfuse hands over for a node it named: its ICU NFD while scanning, the kernel's bytes when exact */
	const char *later = exact ? NFC_CAFE : NFD_CAFE;
	int i;

	lklfuse_nf_exact = exact;
	tap_tag = exact ? "exact: " : "scan: ";

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
	scans = lklfuse_nf_scans;
	snprintf(name, sizeof(name), "/u2/%s", later);
	is(lklfuse_getattr(name, &st, NULL), 0, "enxio_sequence: getattr by the path libfuse hands over");
	is(opens(name), 0, "enxio_sequence: open by the path libfuse hands over");
	is(lklfuse_access(name, R_OK), 0, "enxio_sequence: access by the path libfuse hands over");
	is((int)(lklfuse_nf_scans - scans), 0, "enxio_sequence: no scan");

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
	is(readdir_of("/u5", &s), 0, "neither_form: readdir");
	if (exact) {
		/* listed as stored, so the bytes Finder sends back name it exactly */
		is_str(s.names[0], "a\xcc\x81\xcc\xa3", "neither_form: listed as stored");
		is_str(content_of("/u5/a\xcc\x81\xcc\xa3", buf, sizeof(buf)), "odd", "neither_form: opens by its stored bytes");
		is(opens("/u5/\xe1\xba\xa1\xcc\x81"), -ENOENT, "neither_form: not by its NFC form (no scan to find it)");
	} else {
		is_str(s.names[0], "a\xcc\xa3\xcc\x81", "neither_form: listed in HFS+'s NFD");
		scans = lklfuse_nf_scans;
		is_str(content_of("/u5/\xe1\xba\xa1\xcc\x81", buf, sizeof(buf)), "odd", "neither_form_scan: opens by its NFC form");
		is((int)(lklfuse_nf_scans - scans), 1, "neither_form_scan: lklfuse_nf_scans grows by 1 (open)");
		scans = lklfuse_nf_scans;
		is(lklfuse_getattr("/u5/\xe1\xba\xa1\xcc\x81", &st, NULL), 0, "neither_form_scan: getattr by its NFC form");
		is((int)(lklfuse_nf_scans - scans), 1, "neither_form_scan: lklfuse_nf_scans grows by 1");
	}

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
	f = (struct fuse_file_info){ .flags = O_WRONLY };
	is(lklfuse_create("/u9/\xe2\x84\xab", 0644, &f), 0, "create U+212B");
	lklfuse_release("/u9/\xe2\x84\xab", &f);
	is(names_in("/u9", "\xe2\x84\xab"), 1, "U+212B is stored as given");
	plant("/u9/\xe2\x86\x9a", "arrow");
	if (exact) {
		/* the kernel's bytes, as HFS+ compares them: a singleton is its own name, and no other spelling's */
		is(opens("/u9/\xe2\x84\xa6"), 0, "U+2126 opens by itself");
		is(opens("/u9/\xce\xa9"), -ENOENT, "but not by U+03A9");
		is(opens("/u9/\xe2\x84\xab"), 0, "U+212B opens by itself");
		is(opens("/u9/A\xcc\x8a"), -ENOENT, "but not by A U+030A");
		is(opens("/u9/\xc3\x85"), -ENOENT, "nor by U+00C5");
		is_str(content_of("/u9/\xe2\x86\x9a", buf, sizeof(buf)), "arrow", "a Linux-made U+219A opens by itself");
		is(opens("/u9/\xe2\x86\x90\xcc\xb8"), -ENOENT, "but not by U+2190 U+0338");
	} else {
		is(opens("/u9/\xce\xa9"), 0, "U+2126 opens by U+03A9 (libfuse's ICU NFD of it)");
		is(opens("/u9/A\xcc\x8a"), 0, "U+212B opens by A U+030A (libfuse's ICU NFD of it)");
		is(opens("/u9/\xc3\x85"), 0, "and by U+00C5");
		scans = lklfuse_nf_scans;
		is_str(content_of("/u9/\xe2\x86\x90\xcc\xb8", buf, sizeof(buf)), "arrow",
		       "a Linux-made U+219A opens by U+2190 U+0338 (review N1)");
		is((int)(lklfuse_nf_scans - scans), 1, "through the scan");
	}
	is(readdir_of("/u9", &s), 0, "singletons: readdir");
	for (i = 0; i < s.n; i++)
		if (strcmp(s.names[i], "\xe2\x84\xa6") && strcmp(s.names[i], "\xe2\x84\xab") && strcmp(s.names[i], "\xe2\x86\x9a"))
			break;
	is(s.n == 3 && i == 3, 1, "singletons: listed as stored");

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
	if (exact)
		is((int)(lklfuse_nf_scans - scans0), 0, "lklfuse_nf_scans never grew");
	tap_tag = "";
}

/* a macFUSE manifest at PATH whose version is VERSION (a plist value), with MODE */
static void manifest(const char *path, const char *version, mode_t mode)
{
	FILE *f;

	unlink(path);
	f = fopen(path, "w");
	if (!f)
		return;
	fprintf(f, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
		"<plist version=\"1.0\">\n<dict>\n  <key>identifier</key>\n  <string>dev.mavergreen.macfuse</string>\n"
		"  <key>version</key>\n  %s\n</dict>\n</plist>\n", version);
	fclose(f);
	chmod(path, mode);
}

/* fuse_new, for lklfuse_fuse_new: REJECTS 0 takes anything, 1 refuses -o nonorm_insensitive (a libfuse without
 * it), 2 refuses everything. FAKE_OPT: whether each call had the option. */
static int fake_rejects, fake_calls, fake_opt[2];

static struct fuse *fake_new(struct fuse_args *args, const struct fuse_operations *ops, size_t size, void *data)
{
	int i, has = 0;

	for (i = 0; i < args->argc; i++)
		has |= strcmp(args->argv[i], "-ononorm_insensitive") == 0;
	if (fake_calls < 2)
		fake_opt[fake_calls] = has;
	fake_calls++;
	if (fake_rejects == 2 || (fake_rejects == 1 && has))
		return NULL;
	return (struct fuse *)&fake_calls;
}

static char said[2048];	/* what lklfuse_fuse_new said on stderr */

static struct fuse *new_saying(struct fuse_args *args, const char *path, int rejects)
{
	FILE *t = tmpfile();
	struct fuse *f;
	int save = dup(2);
	size_t n = 0;

	fake_rejects = rejects;
	fake_calls = fake_opt[0] = fake_opt[1] = 0;
	fflush(stderr);
	if (t)
		dup2(fileno(t), 2);
	f = lklfuse_fuse_new(args, NULL, 0, path, getuid(), fake_new);
	fflush(stderr);
	dup2(save, 2);
	close(save);
	if (t) {
		rewind(t);
		n = fread(said, 1, sizeof(said) - 1, t);
		fclose(t);
	}
	said[n] = '\0';
	return f;
}

/* names_mode_*: the pass-through is taken from the installed macFUSE's version, as tools/fs.c's /dev/fd/N gate is */
static void names_mode_tests(void)
{
	static const struct { const char *version; int exact; const char *what; } v[] = {
		{ "<string>5.5.0-mavericks.5</string>", 1, "names_mode: 5.5.0-mavericks.5 passes names through" },
		{ "<string>5.5.0-mavericks.10</string>", 1, "names_mode: 5.5.0-mavericks.10 too (numbers, not text)" },
		{ "<string>5.5.1-mavericks.1</string>", 1, "names_mode: 5.5.1-mavericks.1 too" },
		{ "<string>6.0.0-mavericks.1</string>", 1, "names_mode: 6.0.0-mavericks.1 too" },
		{ "<string>5.5.0-mavericks.4</string>", 0, "names_mode: 5.5.0-mavericks.4 does not" },
		{ "<string>5.4.9-mavericks.9</string>", 0, "names_mode: 5.4.9-mavericks.9 does not" },
		{ "<string>5.5.0</string>", 0, "names_mode: a version that is not Mavergreen's does not" },
		{ "<string>5.5.0-mavericks.5x</string>", 0, "names_mode: nor one with trailing text" },
		{ "<integer>6</integer>", 0, "names_mode: nor a version that is not a string" },
	};
	char dir[] = "/tmp/lklfuse-ops.XXXXXX", path[64], link_path[64], ver[64];
	size_t i;

	if (!mkdtemp(dir)) {
		is(0, 1, "names_mode: a temporary directory");
		return;
	}
	snprintf(path, sizeof(path), "%s/mavergreen.plist", dir);
	snprintf(link_path, sizeof(link_path), "%s/link.plist", dir);
	for (i = 0; i < ARRAY_SIZE(v); i++) {
		manifest(path, v[i].version, 0644);
		is(lklfuse_macfuse_exact(path, getuid(), ver, sizeof(ver)), v[i].exact, v[i].what);
	}
	manifest(path, "<string>5.5.0-mavericks.5</string>", 0644);
	is(lklfuse_macfuse_exact(path, getuid(), ver, sizeof(ver)), 1, "names_mode: read back");
	is_str(ver, "5.5.0-mavericks.5", "names_mode: and the version it read, for the log");
	is(lklfuse_macfuse_exact(path, getuid() + 1, ver, sizeof(ver)), 0, "names_mode: a manifest someone else owns is not read");
	chmod(path, 0664);
	is(lklfuse_macfuse_exact(path, getuid(), ver, sizeof(ver)), 0, "names_mode: nor one its group can write");
	chmod(path, 0646);
	is(lklfuse_macfuse_exact(path, getuid(), ver, sizeof(ver)), 0, "names_mode: nor one anyone can write");
	chmod(path, 0644);
	symlink(path, link_path);
	is(lklfuse_macfuse_exact(link_path, getuid(), ver, sizeof(ver)), 0, "names_mode: nor a symlink");
	unlink(link_path);
	unlink(path);
	is(lklfuse_macfuse_exact(path, getuid(), ver, sizeof(ver)), 0, "names_mode: no manifest: scanning");
	is(ver[0], 0, "names_mode: and no version");

	/* what lklfuse hands libfuse, the mode that runs, and what it says (review M1: only once fuse_new took it) */
	{
		static const struct {
			const char *version;
			int rejects, calls, first_opt, exact, made;
			const char *said, *what;
		} c[] = {
			{ "5.5.0-mavericks.5", 0, 1, 1, 1, 1, "lklfuse: names: exact (macFUSE 5.5.0-mavericks.5",
			  "fuse_new_names: .5, libfuse takes -o nonorm_insensitive" },
			{ "5.5.0-mavericks.5", 1, 2, 1, 0, 1, "lklfuse: names: scanning",
			  "fuse_new_names: .5, libfuse refuses the option: one retry without it" },
			{ "5.5.0-mavericks.5", 2, 2, 1, 0, 0, NULL,
			  "fuse_new_names: .5, fuse_new fails without the option too" },
			{ "5.5.0-mavericks.4", 0, 1, 0, 0, 1, "lklfuse: names: scanning (macFUSE 5.5.0-mavericks.4",
			  "fuse_new_names: .4, no option" },
			{ "5.5.0-mavericks.4", 2, 1, 0, 0, 0, NULL,
			  "fuse_new_names: .4, fuse_new fails: no retry" },
		};
		char what[160];

		for (i = 0; i < ARRAY_SIZE(c); i++) {
			char *argv0[] = { "lklfuse", "-f", NULL };
			struct fuse_args args = FUSE_ARGS_INIT(2, argv0);
			char ver[64];
			struct fuse *made;
			int a, has = 0;

			snprintf(ver, sizeof(ver), "<string>%s</string>", c[i].version);
			manifest(path, ver, 0644);
			made = new_saying(&args, path, c[i].rejects);
			snprintf(what, sizeof(what), "%s: made %s", c[i].what, c[i].made ? "it" : "nothing");
			is(made != NULL, c[i].made, what);
			snprintf(what, sizeof(what), "%s: fuse_new called %d time(s)", c[i].what, c[i].calls);
			is(fake_calls, c[i].calls, what);
			snprintf(what, sizeof(what), "%s: the first call %s the option", c[i].what, c[i].first_opt ? "has" : "lacks");
			is(fake_opt[0], c[i].first_opt, what);
			if (c[i].calls == 2) {
				snprintf(what, sizeof(what), "%s: the retry lacks it", c[i].what);
				is(fake_opt[1], 0, what);
			}
			snprintf(what, sizeof(what), "%s: names %s", c[i].what, c[i].exact ? "exact" : "scanned for");
			is(lklfuse_nf_exact, c[i].exact, what);
			for (a = 0; a < args.argc; a++)
				has |= strcmp(args.argv[a], "-ononorm_insensitive") == 0;
			snprintf(what, sizeof(what), "%s: the arguments kept %s the option", c[i].what, c[i].exact ? "have" : "lack");
			is(has, c[i].exact, what);
			snprintf(what, sizeof(what), "%s: says %s", c[i].what, c[i].said ? c[i].said : "no names mode");
			is(c[i].said ? strstr(said, c[i].said) != NULL : strstr(said, "lklfuse: names:") == NULL, 1, what);
			/* a failure with the option is said either way: the retry's own failure follows it */
			snprintf(what, sizeof(what), "%s: %s the refusal", c[i].what, c[i].rejects && c[i].first_opt ? "says" : "never says");
			is(strstr(said, "refused -ononorm_insensitive") != NULL, c[i].rejects && c[i].first_opt, what);
			lklfuse_args_free(&args);
		}
	}
	lklfuse_nf_exact = 0;
	unlink(path);
	rmdir(dir);
}

/* the resolver's cases in a directory of its own made the root, then back to the real root */
static void resolver_tests_in(const char *dir, int exact)
{
	long root = lkl_sys_open("/", LKL_O_RDONLY | LKL_O_DIRECTORY, 0);

	is(root >= 0 && lkl_sys_mkdir(dir, 0755) == 0 && lkl_sys_chroot(dir) == 0 && lkl_sys_chdir("/") == 0, 1, dir);
	resolver_tests(exact);
	is(lkl_sys_fchdir(root) == 0 && lkl_sys_chroot(".") == 0 && lkl_sys_chdir("/") == 0, 1, "back to the root");
	lkl_sys_close(root);
	lklfuse_nf_exact = 0;
}

/* readdir's rule, on its own: HFS+'s form, except a name in neither form (exact) or over NAME_MAX, as stored */
static void shown_tests(void)
{
	char b[NAME_MAX + 1];
	const char *odd = "a\xcc\x81\xcc\xa3";

	lklfuse_nf_exact = 0;
	is_str(lklfuse_nf_shown(odd, b, sizeof(b)), "a\xcc\xa3\xcc\x81", "shown, scanning: a name in neither form, in HFS+'s NFD");
	lklfuse_nf_exact = 1;
	is(lklfuse_nf_shown(odd, b, sizeof(b)) == odd, 1, "shown, exact: a name in neither form, as stored");
	is_str(lklfuse_nf_shown(NFC_CAFE, b, sizeof(b)), NFD_CAFE, "shown, exact: an NFC name, in HFS+'s NFD");
	is_str(lklfuse_nf_shown(NFD_CAFE, b, sizeof(b)), NFD_CAFE, "shown, exact: an NFD name, as it is");
	is_str(lklfuse_nf_shown("plain", b, sizeof(b)), "plain", "shown, exact: ASCII");
	lklfuse_nf_exact = 0;
}

static mode_t mode_of(const char *path)
{
	struct stat st;

	return lklfuse_getattr(path, &st, NULL) == 0 ? st.st_mode : 0;
}

/*
 * owner=caller (spec: item 6, "Ignore ownership" off, the CLI's --owners): what a Mac user creates is that user's, by the
 * FUSE request's uid, and its group is the directory's it is made in, as on HFS+ (BSD's rule, which also keeps a Linux
 * setgid directory's group); never LKL's root. Linux's chown drops a setuid or setgid bit a create asked for
 * (ATTR_KILL_SUID); one the owner sets afterwards stays, the owner's own.
 */
static void caller_owner_tests(void)
{
	struct fuse_file_info fi = { .flags = O_WRONLY };
	uid_t ru;
	gid_t rg;

	lklfuse.owner = "caller";
	is(lklfuse_set_owner(), 0, "owner=caller is taken");
	test_ctx.uid = 501;
	test_ctx.gid = 20;
	test_ctx_set = 1;
	owner_of("/", &ru, &rg);
	is(lklfuse_mkdir("/c", 0755), 0, "owner=caller: mkdir by uid 501");
	owned("/c", 501, rg, "owner=caller: a new directory is the caller's, its group /'s, not the caller's 20");
	lkl_sys_chown("/c", 501, 20);
	is(lklfuse_create("/c/f", 0644, &fi), 0, "owner=caller: create by uid 501");
	lklfuse_release("/c/f", &fi);
	owned("/c/f", 501, 20, "owner=caller: a file created by uid 501 is 501:20");
	is(lklfuse_symlink("f", "/c/l"), 0, "owner=caller: symlink");
	owned("/c/l", 501, 20, "owner=caller: a new symlink itself is the caller's");
	is(lklfuse_mknod("/c/p", S_IFIFO | 0644, 0), 0, "owner=caller: mknod");
	owned("/c/p", 501, 20, "owner=caller: a new fifo is the caller's");
	fi.flags = O_WRONLY;
	is(lklfuse_create("/c/s", 04755, &fi), 0, "owner=caller: create mode 4755 by uid 501");
	lklfuse_release("/c/s", &fi);
	owned("/c/s", 501, 20, "owner=caller: a 4755 create by a non-root caller is the caller's, not root's");
	is(!!(mode_of("/c/s") & (S_ISUID | S_ISGID)), 0, "and its setuid bit is gone (Linux's chown drops it)");
	is(lklfuse_chmod("/c/s", 04755, NULL), 0, "the owner sets the setuid bit afterwards");
	is(!!(mode_of("/c/s") & S_ISUID), 1, "it stays, on a file the owner owns (as on HFS+)");
	owned("/c/s", 501, 20, "and the file is still the owner's");
	test_ctx.uid = 502;
	test_ctx.gid = 12;
	fi.flags = O_WRONLY;
	is(lklfuse_create("/c/f", 0644, &fi), 0, "owner=caller: create of an existing file by another caller");
	lklfuse_release("/c/f", &fi);
	owned("/c/f", 501, 20, "does not change its owner");
	/* the directory's group, not the caller's: a setgid one (Linux's inheritance) and a plain one (BSD's rule) */
	test_ctx.uid = 501;
	test_ctx.gid = 20;
	lkl_sys_mkdir("/c/sg", 0777);
	lkl_sys_chown("/c/sg", 0, 77);
	lkl_sys_chmod("/c/sg", 02777);
	lkl_sys_mkdir("/c/g", 0777);
	lkl_sys_chown("/c/g", 0, 78);
	lkl_sys_chmod("/c/g", 0777);
	fi.flags = O_WRONLY;
	is(lklfuse_create("/c/sg/f", 0644, &fi), 0, "owner=caller: create in a setgid directory of group 77");
	lklfuse_release("/c/sg/f", &fi);
	owned("/c/sg/f", 501, 77, "the file is the caller's, its group the directory's (77)");
	is(lklfuse_mkdir("/c/sg/d", 0755), 0, "owner=caller: mkdir in it");
	owned("/c/sg/d", 501, 77, "the directory is the caller's, group 77");
	is(!!(mode_of("/c/sg/d") & S_ISGID), 1, "and it keeps the setgid bit Linux gave it, so its own files are 77's too");
	is(lklfuse_symlink("f", "/c/sg/l"), 0, "owner=caller: symlink in it");
	owned("/c/sg/l", 501, 77, "the symlink is the caller's, group 77");
	fi.flags = O_WRONLY;
	is(lklfuse_create("/c/g/f", 0644, &fi), 0, "owner=caller: create in a plain directory of group 78");
	lklfuse_release("/c/g/f", &fi);
	owned("/c/g/f", 501, 78, "the file's group is the directory's (78), as on HFS+");
	is(lklfuse_mknod("/c/g/p", S_IFIFO | 0644, 0), 0, "owner=caller: mknod in it");
	owned("/c/g/p", 501, 78, "the fifo's group is the directory's (78)");
	/* a by-name chown takes only the node just made: one LKL made (its uid 0) and, unless a directory, the only link */
	lkl_sys_mknod("/c/h1", S_IFREG | 0644, 0);
	lkl_sys_link("/c/h1", "/c/h2");
	is(lklfuse_chown_new("/c/h2", 501, 20), 0, "a name with a second hard link is not chowned");
	owned("/c/h1", 0, 0, "and the file it names keeps its owner");
	lkl_sys_mknod("/c/o", S_IFREG | 0644, 0);
	lkl_sys_chown("/c/o", 42, 43);
	is(lklfuse_chown_new("/c/o", 501, 20), 0, "a name someone already owns is not chowned");
	owned("/c/o", 42, 43, "and keeps its owner");
	lkl_sys_mknod("/c/n", S_IFREG | 0644, 0);
	is(lklfuse_chown_new("/c/n", 501, 20), 1, "a new name LKL made, with one link, is chowned");
	owned("/c/n", 501, 20, "to the ids given");
	{	/* a parent that cannot be stat'ed (gone): still the caller's, in the caller's own group, never LKL's 0:0 */
		unsigned int u = 0, g = 0;

		test_ctx.uid = 501;
		test_ctx.gid = 20;
		is(lklfuse_owner_ids("/c/gone/x", &u, &g), 1, "owner=caller, the parent's stat failing: still chowned");
		is((int)u, 501, "to the caller's uid");
		is((int)g, 20, "and, with no directory to take it from, the caller's gid");
	}
	test_ctx_set = 0;
	is(lklfuse_mkdir("/c/none", 0755), 0, "owner=caller with no FUSE caller: mkdir");
	owned("/c/none", 0, 0, "keeps LKL's own ids");
	lklfuse.owner = NULL;
	lklfuse_set_owner();
}

static void unicode_tests(void)
{
	unicode_conv_tests();
	names_mode_tests();
	shown_tests();
	resolver_tests_in("/scan", 0);
	resolver_tests_in("/exact", 1);
}

/*
 * FUSE_DESTROY (patch 0015). macFUSE's unmount sends it after vflush and waits for the answer, and libfuse answers only
 * once lklfuse's destroy returns: so the disk and the lock let go of there are free before unmount(2) returns and
 * DiskArbitration ejects (the hfs-fsname kit's residual 0x10).
 */
static int same_file(int fd, const struct stat *st)
{
	struct stat now;

	return fstat(fd, &now) == 0 && now.st_dev == st->st_dev && now.st_ino == st->st_ino;
}

/* lklfuse_destroy(NULL) with its stderr kept in SAID (at most N bytes, NUL-terminated) */
static void destroy_saying(char *said, size_t n)
{
	char path[PATH_MAX];
	const char *tmp = getenv("TMPDIR");
	int f, saved;
	ssize_t got = 0;

	snprintf(path, sizeof(path), "%s/lklfuse-ops-said.XXXXXX", tmp && *tmp ? tmp : "/tmp");
	f = mkstemp(path);
	fflush(stderr);
	saved = dup(2);
	if (f >= 0)
		dup2(f, 2);
	lklfuse_destroy(NULL);
	fflush(stderr);
	dup2(saved, 2);
	close(saved);
	if (f >= 0) {
		got = pread(f, said, n - 1, 0);
		close(f);
		unlink(path);
	}
	said[got > 0 ? got : 0] = '\0';
}

static int lock_free(const char *path)
{
	int other = open(path, O_RDWR), r;

	r = other >= 0 && flock(other, LOCK_EX | LOCK_NB) == 0;
	if (other >= 0)
		close(other);
	return r;
}

static void destroy_tests(const char *image)
{
	char lockpath[PATH_MAX];
	const char *tmp = getenv("TMPDIR");
	unsigned char b[4];
	struct statvfs vfs;
	struct stat img;
	char said[512];
	long busy;
	int lf, fd;

	snprintf(lockpath, sizeof(lockpath), "%s/lklfuse-ops-lock.XXXXXX", tmp && *tmp ? tmp : "/tmp");
	lf = mkstemp(lockpath);
	is(lf >= 0 && flock(lf, LOCK_EX | LOCK_NB) == 0, 1, "destroy: a lock held, as lock= holds one");
	lklfuse_lockfd = lf;
	is(stat(image, &img) == 0 && same_file(lklfuse.disk.fd, &img), 1, "before destroy, the disk descriptor is the image");
	/* a file open for writing in LKL: the read-only remount is refused (EBUSY), so destroy keeps everything */
	busy = lkl_sys_open("/destroy-busy", LKL_O_WRONLY | LKL_O_CREAT | LKL_O_TRUNC, 0644);
	is(busy >= 0, 1, "destroy: an LKL file held open for writing");
	destroy_saying(said, sizeof(said));
	is(strstr(said, "cannot make the volume read-only at unmount") != NULL, 1, "destroy says it cannot make the volume read-only");
	is(lklfuse_released, 0, "and does not count the disk released");
	is(same_file(lklfuse.disk.fd, &img), 1, "and the disk descriptor is still the image");
	is(lock_free(lockpath), 0, "and the lock is still held");
	is(lklfuse_statfs("/", &vfs) == 0 && !(vfs.f_flag & ST_RDONLY), 1, "and LKL's mount is still writable");
	is(lklfuse_mkdir("/while-busy", 0755), 0, "so a write still goes through");
	if (busy >= 0)
		lkl_sys_close(busy);
	lklfuse_destroy(NULL);
	is(same_file(lklfuse.disk.fd, &img), 0, "after destroy, the device is closed: no descriptor of lklfuse's names it");
	is(fcntl(lklfuse.disk.fd, F_GETFD) >= 0, 1, "and its number stays taken, so LKL's copy of it reaches nothing else");
	is(lock_free(lockpath), 1, "after destroy, the lock is free for the next mount");
	unlink(lockpath);
	is(lklfuse_statfs("/", &vfs) == 0 && (vfs.f_flag & ST_RDONLY), 1, "after destroy, LKL's mount is read-only");
	is(lklfuse_mkdir("/after-destroy", 0755) < 0, 1, "and a write fails: nothing more reaches the disk");
	fd = open(image, O_RDONLY);
	is(fd >= 0 && pread(fd, b, 2, 1024 + 0x3a) == 2 && (b[0] & 1), 1, "after destroy, the image's superblock says clean (s_state)");
	is(fd >= 0 && pread(fd, b, 4, 1024 + 0x60) == 4 && !(b[0] & 4), 1, "and needs no journal recovery");
	if (fd >= 0)
		close(fd);
	lklfuse_destroy(NULL);
	is(same_file(lklfuse.disk.fd, &img), 0, "a second destroy changes nothing");
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
	{
		/* spec: item 6 (capacity) -- statfs as Linux has it: macFUSE takes frsize for the block size, and Finder and df
		 * read the same counts (an ext4 image keeps 5% for root, so bfree and bavail differ) */
		struct lkl_statfs l;
		struct statvfs v;

		memset(&v, 0, sizeof(v));
		is(lkl_sys_statfs("/", &l) == 0 && lklfuse_statfs("/", &v) == 0, 1, "statfs: LKL's and lklfuse's");
		is((unsigned long long)v.f_frsize == (unsigned long long)l.f_frsize && v.f_frsize > 0, 1, "statfs: f_frsize is LKL's");
		is((unsigned long long)v.f_blocks * v.f_frsize == (unsigned long long)l.f_blocks * l.f_frsize, 1,
		   "statfs: f_blocks*f_frsize is LKL's size");
		is((unsigned long long)v.f_bavail * v.f_frsize == (unsigned long long)l.f_bavail * l.f_frsize, 1,
		   "statfs: f_bavail*f_frsize is LKL's available");
		is((unsigned long long)v.f_bfree * v.f_frsize == (unsigned long long)l.f_bfree * l.f_frsize, 1,
		   "statfs: f_bfree*f_frsize is LKL's free");
		is(v.f_bavail < v.f_bfree, 1, "statfs: available is below free (root's reserve), not swapped with it");
	}
#ifdef __APPLE__
	caller_owner_tests();
	unicode_tests();
	destroy_tests(argv[1]);
#endif
	stop_lkl();
#ifdef __APPLE__
	{
		/* libfuse's own destroy, when no FUSE_DESTROY came (SIGTERM): LKL has halted, so it must not be called. Reset
		 * what destroy_tests let go of, so only lklfuse_stopped stands in the way. */
		char said[512];
		struct stat img;
		int n = open(argv[1], O_RDWR);

		is(n >= 0 && dup2(n, lklfuse.disk.fd) == lklfuse.disk.fd, 1, "after stop_lkl: the disk descriptor names the image again");
		if (n >= 0)
			close(n);
		lklfuse_released = 0;
		lklfuse_lockfd = -1;
		destroy_saying(said, sizeof(said));
		is(said[0], '\0', "destroy after LKL has stopped says nothing: no sync or remount was tried");
		is(stat(argv[1], &img) == 0 && same_file(lklfuse.disk.fd, &img), 1, "and leaves the disk descriptor as it was");
		is(lklfuse_released, 0, "and does not count the disk released");
	}
#endif
	lkl_cleanup();
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}

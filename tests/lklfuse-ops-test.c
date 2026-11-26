/*
 * lklfuse's callbacks, called directly (no FUSE mount) on an ext4 image, checking what the host's
 * FUSE layer would be told: host errno values, and host xattr/rename flags translated. On Darwin
 * these differ from Linux's numbers, which LKL returns. Built with lklfuse.c itself included.
 * usage: lklfuse-ops-test EXT4-IMAGE [XATTR-IMAGE-DIR]
 *        XATTR-IMAGE-DIR (Darwin): tests/lib/xattr-images.sh's four images, for the Mac xattr schemes (patch 0013)
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
 * The volume icon (patch 0017, spec: item 6 amendment, -o volicon=PATH): with no /.VolumeIcon.icns of the volume's own,
 * lookup and getattr answer a read-only file whose bytes are PATH's, the root's com.apple.FinderInfo says it has a custom
 * icon, readdir does not list it, nothing can change it, and nothing reaches the disk. A real one wins, at once.
 */
static int volicon_listed;

static int volicon_fill(void *buf, const char *name, const struct stat *st, off_t off, enum fuse_fill_dir_flags flags)
{
	if (strcmp(name, ".VolumeIcon.icns") == 0)
		volicon_listed++;
	return 0;
}

static int volicon_in_readdir(void)
{
	struct fuse_file_info f = { 0 };

	volicon_listed = 0;
	if (lklfuse_opendir("/", &f))
		return -1;
	lklfuse_readdir("/", NULL, volicon_fill, 0, &f, 0);
	lklfuse_releasedir("/", &f);
	return volicon_listed;
}

/* listxattr of PATH has NAME */
static int lists(const char *path, const char *name)
{
	char b[1024];
	int n = lklfuse_listxattr(path, b, sizeof(b)), off;

	for (off = 0; n > 0 && off < n; off += strlen(b + off) + 1)
		if (strcmp(b + off, name) == 0)
			return 1;
	return 0;
}

/* how many times listxattr of PATH has NAME; or, with PREFIX set, names starting with NAME */
static int listed(const char *path, const char *name, int prefix)
{
	char b[4096];
	int n = lklfuse_listxattr(path, b, sizeof(b)), off, count = 0;

	for (off = 0; n > 0 && off < n; off += strlen(b + off) + 1)
		count += prefix ? strncmp(b + off, name, strlen(name)) == 0 : strcmp(b + off, name) == 0;
	return count;
}

static void volicon_tests(void)
{
	const char *V = "/.VolumeIcon.icns", *FI = "com.apple.FinderInfo";
	char path[PATH_MAX], b[64], icon[3000], got[3000];
	const char *tmp = getenv("TMPDIR");
	struct fuse_file_info fi = { .flags = O_RDONLY };
	struct stat st, root;
	struct statvfs vfs;
	size_t i;
	int f, n;

	is(lklfuse_getattr(V, &st, NULL), -ENOENT, "volicon: without the option, there is no /.VolumeIcon.icns");
	is(lklfuse_getxattr("/", FI, b, sizeof(b)), -HOST_ENOATTR, "volicon: without it, the root has no FinderInfo of its own (ENOATTR)");
	for (i = 0; i < sizeof(icon); i++)
		icon[i] = (char)(i * 7 + 3);
	snprintf(path, sizeof(path), "%s/lklfuse-ops-icon.XXXXXX", tmp && *tmp ? tmp : "/tmp");
	f = mkstemp(path);
	is(f >= 0 && write(f, icon, sizeof(icon)) == (ssize_t)sizeof(icon), 1, "volicon: an icon file of 3000 bytes");
	if (f >= 0)
		close(f);
	lklfuse.volicon = "/nonexistent/linuxfs.icns";
	is(lklfuse_volicon_open(), -1, "volicon: a missing icon file is refused, and said");
	is(lklfuse_getattr(V, &st, NULL), -ENOENT, "volicon: so there is no icon");
	lklfuse.volicon = path;
	is(lklfuse_volicon_open(), 0, "volicon=PATH: the icon file is opened");
	lkl_sys_chown("/", 1234, 5678);
	is(lklfuse_getattr("/", &root, NULL), 0, "volicon: the root's attributes");
	is(lklfuse_getattr(V, &st, NULL), 0, "volicon: getattr (lookup) of /.VolumeIcon.icns answers");
	is(S_ISREG(st.st_mode), 1, "volicon: a regular file");
	is((int)(st.st_mode & 07777), 0644, "volicon: 0644: its owner may replace it (making a real one), never write its bytes");
	is((int)st.st_size, (int)sizeof(icon), "volicon: its size is the icon file's");
	is((int)st.st_nlink, 1, "volicon: one link");
	is((int)st.st_uid, (int)root.st_uid, "volicon: its owner is the root's (mapped as every other file)");
	is((int)st.st_gid, (int)root.st_gid, "volicon: its group is the root's");
	is(st.st_ino != root.st_ino && st.st_ino != 0, 1, "volicon: its inode number is its own");
	is(lklfuse_open(V, &fi), 0, "volicon: open for reading");
	memset(got, 0, sizeof(got));
	is(lklfuse_read(NULL, got, sizeof(got), 0, &fi), (int)sizeof(icon), "volicon: read gives all its bytes (no path: nullpath_ok)");
	is(memcmp(got, icon, sizeof(icon)), 0, "volicon: and they are the icon file's");
	is(lklfuse_read(NULL, got, 10, 2990, &fi), 10, "volicon: a read at an offset");
	is(memcmp(got, icon + 2990, 10), 0, "volicon: gives the bytes there");
	is(lklfuse_read(NULL, got, 10, 3000, &fi), 0, "volicon: a read at the end gives nothing");
	memset(&st, 0, sizeof(st));
	is(lklfuse_getattr(NULL, &st, &fi) == 0 && (int)st.st_size == (int)sizeof(icon), 1, "volicon: getattr of the open file");
	is(lklfuse_write(NULL, "x", 1, 0, &fi) < 0, 1, "volicon: a write to it fails");
	is(lklfuse_truncate(NULL, 0, &fi), -EACCES, "volicon: ftruncate of it: EACCES");
	is(lklfuse_chmod(NULL, 0644, &fi), -EACCES, "volicon: fchmod of it: EACCES");
	is(lklfuse_release(NULL, &fi), 0, "volicon: release");
	is_str(content_of(V, b, 8), "\x03\x0a\x11\x18\x1f\x26\x2d", "volicon: content_of reads it too");
	/* the icon's own bytes and attributes cannot be changed, nor the icon moved, linked or removed */
	/* (fix round 2) unlink of the icon alone: ENOENT, the name is free on the disk, so unlink-then-create replacers
	 * (install, ln -sf, cp -f, rsync) go on */
	is(lklfuse_unlink(V), -ENOENT, "volicon: unlink of the icon alone: ENOENT, nothing of that name on the disk");
	is(lklfuse_getattr(V, &st, NULL) == 0 && st.st_ino == LKLFUSE_VOLICON_INO, 1, "volicon: and the icon is still shown");
	is(lklfuse_rename(V, "/vi-moved", 0), -EACCES, "volicon: rename away: EACCES");
	is(lklfuse_link(V, "/vi-link"), -EACCES, "volicon: a hard link to it: EACCES");
	is(lklfuse_chmod(V, 0644, NULL), -EACCES, "volicon: chmod: EACCES");
	is(lklfuse_chown(V, 1, 1, NULL), -EACCES, "volicon: chown: EACCES");
	is(lklfuse_utimens(V, (struct timespec[2]){ { 0, 0 }, { 0, 0 } }, NULL), -EACCES, "volicon: utimens: EACCES");
	is(lklfuse_setxattr(V, "user.k", "1", 1, 0), -EACCES, "volicon: setxattr on it: EACCES");
	is(lklfuse_removexattr(V, "user.k"), -EACCES, "volicon: removexattr on it: EACCES");
	is(lklfuse_getxattr(V, "user.k", b, sizeof(b)), -HOST_ENOATTR, "volicon: it has no xattrs");
	is(lklfuse_listxattr(V, b, sizeof(b)), 0, "volicon: and lists none");
	is(lklfuse_access(V, R_OK), 0, "volicon: access for reading");
	is(lklfuse_access(V, X_OK), -EACCES, "volicon: access for running: EACCES");
	is(lklfuse_access(V, W_OK), 0, "volicon: access for writing: as / allows making a file there (it does)");
	is(lklfuse_readlink(V, b, sizeof(b)), -EINVAL, "volicon: readlink: EINVAL, not a symlink");
	is(lklfuse_opendir(V, &fi), -ENOTDIR, "volicon: opendir: ENOTDIR");
	is(lklfuse_statfs(V, &vfs), 0, "volicon: statfs through it is the volume's");
	is(names_in("/", ".VolumeIcon.icns"), 0, "volicon: after all that, nothing of that name is on the disk");
	is(names_in("/", "vi-moved") + names_in("/", "vi-link"), 0, "volicon: and nothing was moved or linked");
	/* the user's own icon (controller ruling, fix round 1): making a file under the name acts on the disk as if the name
	 * were free, so a real /.VolumeIcon.icns is made, and it wins at once */
	fi.flags = O_WRONLY | O_TRUNC;
	is(lklfuse_open(V, &fi), 0, "volicon: cp's open (O_WRONLY|O_TRUNC) over the icon makes a real file");
	is(lklfuse_write(NULL, "mine", 4, 0, &fi), 4, "volicon: cp writes it");
	is(lklfuse_release(NULL, &fi), 0, "volicon: and closes it");
	is(names_in("/", ".VolumeIcon.icns"), 1, "volicon: the real file is on the disk");
	is_str(content_of(V, b, sizeof(b)), "mine", "volicon: and its bytes are what is served");
	is(lklfuse_getattr(V, &st, NULL) == 0 && st.st_size == 4 && st.st_ino != LKLFUSE_VOLICON_INO, 1, "volicon: its attributes too");
	is(lklfuse_unlink(V), 0, "volicon: the real one can be removed");
	is(lklfuse_getattr(V, &st, NULL) == 0 && (int)st.st_size == (int)sizeof(icon), 1, "volicon: and the icon is back");
	/* (fix round 2) a write-open without O_TRUNC edits the icon in place: the real file made starts as the icon's bytes */
	fi.flags = O_RDWR;
	is(lklfuse_open(V, &fi), 0, "volicon: a read-write open (no O_TRUNC) makes a real file");
	is(lklfuse_write(NULL, "\xff", 1, 5, &fi), 1, "volicon: a 1-byte patch at offset 5");
	is(lklfuse_release(NULL, &fi), 0, "volicon: and closes it");
	memset(got, 0, sizeof(got));
	is(lklfuse_getattr(V, &st, NULL) == 0 && st.st_ino != LKLFUSE_VOLICON_INO && st.st_size == (off_t)sizeof(icon), 1,
	   "volicon: the real file has the icon's size");
	fi.flags = O_RDONLY;
	is(lklfuse_open(V, &fi), 0, "volicon: open it to read");
	is(lklfuse_read(NULL, got, sizeof(got), 0, &fi), (int)sizeof(icon), "volicon: read it whole");
	lklfuse_release(NULL, &fi);
	icon[5] = (char)0xff;
	is(memcmp(got, icon, sizeof(icon)), 0, "volicon: its bytes are the icon's, with the patch landed");
	icon[5] = (char)(5 * 7 + 3);
	lkl_sys_unlink(V);
	fi.flags = O_WRONLY;
	is(lklfuse_open(V, &fi), 0, "volicon: a lock-only write-open (no O_TRUNC, no write)");
	lklfuse_release(NULL, &fi);
	memset(got, 0, sizeof(got));
	fi.flags = O_RDONLY;
	is(lklfuse_open(V, &fi) == 0 && lklfuse_getattr(V, &st, NULL) == 0 && st.st_ino != LKLFUSE_VOLICON_INO, 1,
	   "volicon: makes a real file");
	is(lklfuse_read(NULL, got, sizeof(got), 0, &fi), (int)sizeof(icon), "volicon: which holds the icon's bytes whole");
	lklfuse_release(NULL, &fi);
	is(memcmp(got, icon, sizeof(icon)), 0, "volicon: unchanged");
	lkl_sys_unlink(V);
	/* ln -sf, install, cp -f: unlink (ENOENT, gone) then make the name */
	is(lklfuse_unlink(V) == -ENOENT && lklfuse_symlink("elsewhere", V) == 0, 1, "volicon: ln -sf over the icon: unlink then symlink");
	is(lklfuse_readlink(V, b, sizeof(b)) == 0 && strcmp(b, "elsewhere") == 0, 1, "volicon: the symlink is what is there");
	lkl_sys_unlink(V);
	fi.flags = O_WRONLY;
	is(lklfuse_unlink(V) == -ENOENT && lklfuse_create(V, 0644, &fi) == 0, 1, "volicon: install over the icon: unlink then create");
	is(lklfuse_write(NULL, "inst", 4, 0, &fi), 4, "volicon: install writes it");
	lklfuse_release(NULL, &fi);
	is_str(content_of(V, b, sizeof(b)), "inst", "volicon: and it is served");
	lkl_sys_unlink(V);
	fi.flags = O_RDONLY | O_TRUNC;
	is(lklfuse_open(V, &fi), 0, "volicon: an O_TRUNC open makes a real, empty file");
	lklfuse_release(NULL, &fi);
	is(lklfuse_getattr(V, &st, NULL) == 0 && st.st_size == 0, 1, "volicon: empty");
	lkl_sys_unlink(V);
	fi.flags = O_WRONLY;
	is(lklfuse_create(V, 0644, &fi), 0, "volicon: create (FUSE_CREATE) makes a real file");
	lklfuse_release(NULL, &fi);
	is(names_in("/", ".VolumeIcon.icns"), 1, "volicon: on the disk");
	lkl_sys_unlink(V);
	plant("/vi-src", "renamed");
	is(lklfuse_rename("/vi-src", V, 0), 0, "volicon: mv onto the icon works");
	is_str(content_of(V, b, sizeof(b)), "renamed", "volicon: the moved file is served");
	is(names_in("/", "vi-src"), 0, "volicon: and it left its old name");
	lkl_sys_unlink(V);
	plant("/vi-src", "linked");
	is(lklfuse_link("/vi-src", V), 0, "volicon: a hard link under its name works");
	is_str(content_of(V, b, sizeof(b)), "linked", "volicon: and is served");
	lkl_sys_unlink(V);
	lkl_sys_unlink("/vi-src");
	is(lklfuse_truncate(V, 10, NULL), 0, "volicon: truncate (setattr size) of the icon makes a real file");
	is(lklfuse_getattr(V, &st, NULL) == 0 && st.st_size == 10 && S_ISREG(st.st_mode), 1, "volicon: of that size");
	lkl_sys_unlink(V);
	is(lklfuse_mkdir(V, 0755), 0, "volicon: mkdir under its name works");
	is(lklfuse_getattr(V, &st, NULL) == 0 && S_ISDIR(st.st_mode), 1, "volicon: and that directory is what is there");
	lkl_sys_rmdir(V);
	is(lklfuse_symlink("elsewhere", V), 0, "volicon: symlink under its name works");
	lkl_sys_unlink(V);
	is(lklfuse_mknod(V, S_IFIFO | 0644, 0), 0, "volicon: mknod under its name works");
	lkl_sys_unlink(V);
	is(lklfuse_getattr(V, &st, NULL) == 0 && st.st_ino == LKLFUSE_VOLICON_INO, 1, "volicon: with all of those gone, the icon is back");
	is(names_in("/", ".VolumeIcon.icns"), 0, "volicon: and nothing of that name is on the disk");
	is(volicon_in_readdir(), 0, "volicon: readdir of / does not list it");
	/* the root's FinderInfo: a 32-byte FolderInfo whose frFlags (bytes 8-9, big-endian) have kHasCustomIcon, 0x0400 */
	is(lklfuse_getxattr("/", FI, NULL, 0), 32, "volicon: the root's FinderInfo: 32 bytes");
	memset(b, 0x55, sizeof(b));
	is(lklfuse_getxattr("/", FI, b, sizeof(b)), 32, "volicon: read whole");
	is((unsigned char)b[8] == 0x04 && b[9] == 0, 1, "volicon: frFlags has kHasCustomIcon (0x0400, big-endian)");
	for (n = 0, i = 0; i < 32; i++)
		n += i != 8 && b[i] != 0;
	is(n, 0, "volicon: every other byte is 0");
	is(lklfuse_getxattr("/", FI, b, 4), -ERANGE, "volicon: a buffer too small: ERANGE");
	is(lists("/", FI), 1, "volicon: listxattr of / has com.apple.FinderInfo");
	is(lists("/", "user.a"), 1, "volicon: and still the root's own xattrs");
	n = lklfuse_listxattr("/", NULL, 0);
	is(n, lklfuse_listxattr("/", b, sizeof(b)), "volicon: listxattr's size query is its length");
	is(lklfuse_listxattr("/", b, (size_t)n - 1), -ERANGE, "volicon: and one byte short: ERANGE");
	/* item 7 (patch 0013): the root's own FinderInfo is stored, and the flag is merged into it while the icon is shown */
	memset(b, 0, 32);
	b[9] = 0x0c;
	is(lklfuse_setxattr("/", FI, b, 32, 0), 0, "volicon: setting the root's FinderInfo stores the volume's own (item 7)");
	memset(b, 0x55, sizeof(b));
	is(lklfuse_getxattr("/", FI, b, sizeof(b)), 32, "volicon: it reads back");
	is((unsigned char)b[8] == 0x04 && (unsigned char)b[9] == 0x0c, 1, "volicon: with kHasCustomIcon merged into its own frFlags");
	for (n = 0, i = 0; i < 32; i++)
		n += i != 8 && i != 9 && b[i] != 0;
	is(n, 0, "volicon: and its other bytes its own");
	is(lklfuse_getxattr("/", FI, NULL, 0), 32, "volicon: the merged one's size query: 32");
	is(lklfuse_getxattr("/", FI, b, 4), -ERANGE, "volicon: the merged one, a buffer too small: ERANGE");
	is(listed("/", FI, 0), 1, "volicon: listed once");
	is(lkl_sys_getxattr("/", "user.com.apple.FinderInfo", b, sizeof(b)) == 32 && b[8] == 0, 1, "volicon: the flag is never written");
	is(lklfuse_getxattr("/c", FI, b, sizeof(b)), -HOST_ENOATTR, "volicon: another folder's FinderInfo is its own (none)");
	/* a real one wins, at once, and the synthetic one is back as soon as it is gone */
	plant(V, "real");
	is(lklfuse_getattr(V, &st, NULL) == 0 && st.st_size == 4 && (st.st_mode & 07777) == 0644, 1,
	   "volicon: a real /.VolumeIcon.icns wins at once: its own size and mode");
	is_str(content_of(V, b, sizeof(b)), "real", "volicon: and its own bytes");
	is(volicon_in_readdir(), 1, "volicon: readdir lists the real one");
	is(lklfuse_getxattr("/", FI, b, sizeof(b)) == 32 && b[8] == 0 && b[9] == 0x0c, 1,
	   "volicon: and the root's FinderInfo is the volume's own again, without the flag");
	is(listed("/", FI, 0), 1, "volicon: listed once, as the volume's own");
	is(lklfuse_removexattr("/", FI), 0, "volicon: the volume's own can be removed");
	is(lklfuse_getxattr("/", FI, b, sizeof(b)), -HOST_ENOATTR, "volicon: then, with a real icon, the root has none");
	is(lists("/", FI), 0, "volicon: not listed either");
	is(lklfuse_unlink(V), 0, "volicon: the real one can be removed");
	is(lklfuse_getattr(V, &st, NULL) == 0 && (int)st.st_size == (int)sizeof(icon), 1, "volicon: then the icon is back at once");
	lkl_sys_unlink("/vi-src");
	close(lklfuse_volicon_fd);
	lklfuse_volicon_fd = -1;
	lklfuse.volicon = NULL;
	unlink(path);
	is(lklfuse_getattr(V, &st, NULL), -ENOENT, "volicon: with no icon, the name is free again");
}

/*
 * Mac xattrs (patch 0013, spec: item 7). A Mac name N is the Linux name user.N, always; Linux's other namespaces and
 * the carriers of netatalk's and Samba's schemes are never shown under their own names. A file's attribute is read
 * where it already is, changed there, and a new one goes in the file's own scheme, else the volume's. The four images
 * are tests/lib/xattr-images.sh's (one per scheme, and one that mixes them), each mounted in turn beside the test
 * volume; the raw names and bytes are checked with lkl_sys_getxattr, as Linux sees them.
 */
#define XFI "com.apple.FinderInfo"
#define XTAGS "com.apple.metadata:_kMDItemUserTags"
#define XMETA "user.org.netatalk.Metadata"
#define XAFPI "user.DosStream.AFP_AfpInfo:$DATA"
#define XTAGS_STREAM "user.DosStream.com.apple.metadata\xef\x80\xa2_kMDItemUserTags:$DATA"
static const char *const xa_name[] = { "ours", "netatalk", "fruit", "mixed" };
static struct lkl_disk xa_disk[4];
static int xa_id[4] = { -1, -1, -1, -1 };
static long xa_oldroot = -1;
static char fi_planted[32] = "TEXTttxt", fi_new[32] = "TEXTttxt\x00\x0c";

/* before start_lkl: DIR's four images, as LKL disks */
static void xa_add(const char *dir)
{
	char path[PATH_MAX];
	int i, fd;

	for (i = 0; i < 4; i++) {
		snprintf(path, sizeof(path), "%s/ext4-xa-%s.img", dir, xa_name[i]);
		fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		xa_disk[i].fd = fd;
		xa_id[i] = lkl_disk_add(&xa_disk[i]);
	}
}

/* image I is the volume now: mounted, and the root lklfuse's callbacks see; its scheme chosen as at mount */
static int xa_enter(int i)
{
	char mp[32];

	if (xa_id[i] < 0 || lkl_mount_dev(xa_id[i], 0, "ext4", 0, NULL, mp, sizeof(mp)))
		return -1;
	xa_oldroot = lkl_sys_open("/", LKL_O_RDONLY | LKL_O_DIRECTORY, 0);
	if (xa_oldroot < 0 || lkl_sys_chroot(mp) || lkl_sys_chdir("/"))
		return -1;
	lklfuse_xs_vol = lklfuse_volume_xscheme();
	return 0;
}

/* back to the test volume */
static void xa_leave(int i)
{
	lkl_sys_fchdir(xa_oldroot);
	lkl_sys_chroot(".");
	lkl_sys_close(xa_oldroot);
	xa_oldroot = -1;
	lkl_umount_dev(xa_id[i], 0, 0, 1000);
	lklfuse_xs_vol = lklfuse_volume_xscheme();
}

/* Linux xattr NAME of PATH is exactly LEN bytes VAL */
static int raw_is(const char *path, const char *name, const void *val, long len)
{
	char b[4096];

	return lkl_sys_getxattr(path, name, b, sizeof(b)) == len && memcmp(b, val, len) == 0;
}

static int raw_has(const char *path, const char *name)
{
	return lkl_sys_getxattr(path, name, NULL, 0) >= 0;
}

/* lklfuse's FinderInfo of PATH is FI */
static int fi_is(const char *path, const char *fi)
{
	char b[64];

	return lklfuse_getxattr(path, XFI, b, sizeof(b)) == 32 && memcmp(b, fi, 32) == 0;
}

/* what the smoke does (Task 19), left on the image for tests/lib/check-xattrs.sh to read back on Linux: a label, a tag */
static void xa_tag(const char *path)
{
	char what[96];

	snprintf(what, sizeof(what), "%s: labelled and tagged Parity, for check-xattrs.sh", path);
	is(lklfuse_setxattr(path, XFI, fi_new, 32, 0) == 0 && lklfuse_setxattr(path, XTAGS, "bplist00 Parity", 15, 0) == 0, 1, what);
}

static void xname_tests(void)
{
	static const char *const pair[][2] = {
		{ "k", "user.k" }, { "user.k", "user.user.k" }, { "security.foo", "user.security.foo" },
		{ XFI, "user.com.apple.FinderInfo" },
	};
	static const char *const hidden[] = {
		"security.selinux", "trusted.x", "system.posix_acl_access", "osx.k", "user.", XMETA,
		"user.org.netatalk.ResourceFork", XAFPI, "user.DosStream.k:$DATA", "user.DosStreamExt.1.k:$DATA",
	};
	char b[300], what[160], longname[300];
	size_t i;

	for (i = 0; i < sizeof(pair) / sizeof(pair[0]); i++) {
		snprintf(what, sizeof(what), "xname_table: %s -> %s", pair[i][0], pair[i][1]);
		is_str(lklfuse_xname_to_linux(pair[i][0], b, sizeof(b)) == 0 ? b : NULL, pair[i][1], what);
		snprintf(what, sizeof(what), "xname_table: %s -> %s", pair[i][1], pair[i][0]);
		is_str(lklfuse_xname_to_mac(pair[i][1], b, sizeof(b)) == 0 ? b : NULL, pair[i][0], what);
	}
	for (i = 0; i < sizeof(hidden) / sizeof(hidden[0]); i++) {
		snprintf(what, sizeof(what), "xname_table: %s is hidden from the Mac", hidden[i]);
		is(lklfuse_xname_to_mac(hidden[i], b, sizeof(b)), 1, what);
	}
	memset(longname, 'n', sizeof(longname) - 1);
	longname[sizeof(longname) - 1] = '\0';
	is(lklfuse_xname_to_linux(longname, b, sizeof(b)) < 0, 1, "xname_table: a name too long for Linux is refused");
	is(lklfuse_xname_to_mac("user.kk", b, 2), -ERANGE, "xname_table: a Mac name too long for the buffer: ERANGE");
	/* apfs: macOS's own names, as the Linux driver shows them (osx.N) */
	is_str(lklfuse_xpre_for("apfs"), "osx.", "xname_table: on apfs the prefix is osx.");
	is_str(lklfuse_xpre_for("ext4"), "user.", "xname_table: on ext4, user.");
	is_str(lklfuse_xpre_for("ntfs3"), "user.", "xname_table: on ntfs3, user.");
	lklfuse_xpre = lklfuse_xpre_for("apfs");
	is_str(lklfuse_xname_to_linux(XFI, b, sizeof(b)) == 0 ? b : NULL, "osx.com.apple.FinderInfo", "xname_table: apfs: FinderInfo -> osx.com.apple.FinderInfo");
	is_str(lklfuse_xname_to_mac("osx." XTAGS, b, sizeof(b)) == 0 ? b : NULL, XTAGS, "xname_table: apfs: osx.N -> N");
	is(lklfuse_xname_to_mac("user.k", b, sizeof(b)), 1, "xname_table: apfs: user.k is hidden");
	lklfuse_xpre = lklfuse_xpre_for("ext4");
}

static void volume_scheme_tests(void)
{
	static const char *const marker[] = { "/.AppleDB", "/.AppleDouble", "/.AppleDesktop" };
	char blob[402], what[80];
	size_t i;

	is(lklfuse_xs_vol, XS_OURS, "volume_scheme: the blank ext4 test volume, from start_lkl: ours");
	is(lklfuse_volume_xscheme(), XS_OURS, "volume_scheme: blank ext4: XS_OURS");
	for (i = 0; i < sizeof(marker) / sizeof(marker[0]); i++) {
		snprintf(what, sizeof(what), "volume_scheme: a root %s: XS_NETATALK", marker[i] + 1);
		lkl_sys_mkdir(marker[i], 0755);
		is(lklfuse_volume_xscheme(), XS_NETATALK, what);
		lkl_sys_rmdir(marker[i]);
	}
	is(lklfuse_volume_xscheme(), XS_OURS, "volume_scheme: and ours again without them");
	memset(blob, 0, sizeof(blob));
	lkl_sys_setxattr("/", XMETA, blob, sizeof(blob), 0);
	is(lklfuse_volume_xscheme(), XS_NETATALK, "volume_scheme: a netatalk blob on the root: XS_NETATALK");
	lkl_sys_removexattr("/", XMETA);
	plant("/xs-entry", "x");
	lkl_sys_setxattr("/xs-entry", "user.DosStream.k:$DATA", "v", 2, 0);
	is(lklfuse_volume_xscheme(), XS_FRUIT_STREAM, "volume_scheme: a DosStream on a root entry: XS_FRUIT_STREAM");
	lkl_sys_setxattr("/", XMETA, blob, sizeof(blob), 0);
	is(lklfuse_volume_xscheme(), XS_NETATALK, "volume_scheme: netatalk's blob wins over a DosStream");
	lkl_sys_removexattr("/", XMETA);
	lkl_sys_unlink("/xs-entry");
	is(lklfuse_volume_xscheme(), XS_OURS, "volume_scheme: ours once the markers are gone");
}

static void xa_ours_tests(void)
{
	is(xa_enter(0), 0, "ours image: mounted");
	is(lklfuse_xs_vol, XS_OURS, "ours image: the volume's scheme is ours");
	is(fi_is("/f", fi_planted), 1, "ours: getxattr FinderInfo reads user.com.apple.FinderInfo");
	is(listed("/f", XFI, 0) + listed("/f", XTAGS, 0), 2, "ours: listxattr shows FinderInfo and the tag");
	is(listed("/f", "user.", 1), 0, "ours: and no user. name");
	is(lklfuse_setxattr("/f", XFI, fi_new, 32, 0), 0, "ours round trip: set FinderInfo");
	is(fi_is("/f", fi_new), 1, "ours round trip: get it back");
	is(raw_is("/f", "user.com.apple.FinderInfo", fi_new, 32), 1, "ours round trip: stored as user.com.apple.FinderInfo");
	is(raw_has("/f", XMETA) + raw_has("/f", XAFPI), 0, "ours round trip: no carrier made");
	plant("/n", "n");
	is(lklfuse_setxattr("/n", XFI, fi_new, 32, XATTR_CREATE), 0, "ours: a new file's FinderInfo");
	is(raw_is("/n", "user.com.apple.FinderInfo", fi_new, 32), 1, "ours: goes in the volume's scheme, ours");
	is(lklfuse_setxattr("/n", XTAGS, "tag", 3, 0), 0, "ours: a new file's tag");
	is(raw_is("/n", "user." XTAGS, "tag", 3), 1, "ours: stored as user.com.apple.metadata:_kMDItemUserTags");
	xa_tag("/f");
	xa_leave(0);
}

static void xa_netatalk_tests(void)
{
	char before[512], after[512], b[512];
	long n;

	is(xa_enter(1), 0, "netatalk image: mounted");
	is(lklfuse_xs_vol, XS_NETATALK, "netatalk image: the volume's scheme is netatalk (a blob on a root entry)");
	is(listed("/f", XFI, 0), 1, "listxattr_hides: the netatalk file shows com.apple.FinderInfo");
	is(listed("/f", "org.netatalk.Metadata", 0) + listed("/f", XMETA, 0), 0, "listxattr_hides: never org.netatalk.Metadata");
	is(listed("/f", XTAGS, 0), 1, "netatalk: and its tag (user.N, as netatalk stores other xattrs)");
	is(fi_is("/f", fi_planted), 1, "netatalk: getxattr FinderInfo reads the blob's (offset 122)");
	n = lkl_sys_getxattr("/f", XMETA, before, sizeof(before));
	is((int)n, 402, "netatalk: the blob is 402 bytes");
	is(lklfuse_setxattr("/f", XFI, fi_new, 32, XATTR_CREATE), -EEXIST, "netatalk: XATTR_CREATE of the blob's FinderInfo: EEXIST");
	is(lklfuse_setxattr("/f", XFI, fi_new, 32, 0), 0, "netatalk round trip: set FinderInfo");
	is(fi_is("/f", fi_new), 1, "netatalk round trip: get it back");
	is((int)lkl_sys_getxattr("/f", XMETA, after, sizeof(after)), 402, "netatalk round trip: the blob is still 402 bytes");
	is(memcmp(after + 122, fi_new, 32), 0, "netatalk round trip: stored in the blob, at 122");
	is(memcmp(before, after, 122) == 0 && memcmp(before + 154, after + 154, 402 - 154) == 0, 1,
	   "blob_bytes_kept: every byte outside those 32 is as it was");
	is(raw_has("/f", "user.com.apple.FinderInfo"), 0, "netatalk round trip: no user.com.apple.FinderInfo made");
	is(lklfuse_setxattr("/f", XFI, fi_new, 31, 0), -ERANGE, "netatalk: a FinderInfo not 32 bytes long: ERANGE");
	is(lklfuse_setxattr("/f", XTAGS, "tag2", 4, 0), 0, "netatalk: change the tag");
	is(raw_is("/f", "user." XTAGS, "tag2", 4), 1, "netatalk: in user.N, where it was");
	is(lklfuse_setxattr("/f", "org.netatalk.Metadata", "x", 1, 0), -EPERM, "netatalk: the carrier cannot be written by its own name");
	is(lklfuse_getxattr("/f", "org.netatalk.Metadata", b, sizeof(b)), -HOST_ENOATTR, "netatalk: nor read");
	is(raw_is("/f", XMETA, after, 402), 1, "netatalk: so the blob is unchanged");
	/* a new file: the volume's scheme, a new blob in netatalk's layout */
	plant("/n", "n");
	is(lklfuse_setxattr("/n", XFI, fi_new, 32, XATTR_REPLACE), -HOST_ENOATTR, "netatalk: XATTR_REPLACE with no FinderInfo: ENOATTR");
	is(lklfuse_setxattr("/n", XFI, fi_new, 32, 0), 0, "netatalk: a new file's FinderInfo");
	n = lkl_sys_getxattr("/n", XMETA, b, sizeof(b));
	is((int)n, 402, "netatalk: makes a 402-byte blob");
	is(memcmp(b, "\x00\x05\x16\x07\x00\x02\x00\x00", 8) == 0 && b[24] == 0 && b[25] == 8, 1,
	   "netatalk: AppleDouble magic, version 2, 8 entries");
	is(memcmp(b + 26 + 24, "\x00\x00\x00\x09\x00\x00\x00\x7a\x00\x00\x00\x20", 12), 0, "netatalk: its third entry is Finder Info at 122, 32 bytes");
	is(memcmp(b + 122, fi_new, 32), 0, "netatalk: holding the new FinderInfo");
	is(raw_has("/n", "user.com.apple.FinderInfo"), 0, "netatalk: and no user.com.apple.FinderInfo");
	is(fi_is("/n", fi_new), 1, "netatalk: read back");
	/* removing it zeroes the 32 bytes in the blob, which keeps the rest */
	is(lklfuse_removexattr("/f", XFI), 0, "netatalk: removexattr FinderInfo");
	is(lklfuse_getxattr("/f", XFI, b, sizeof(b)), -HOST_ENOATTR, "netatalk: then it is gone (all-zero Finder Info, as HFS+)");
	is(listed("/f", XFI, 0), 0, "netatalk: and not listed");
	memset(after + 122, 0, 32);
	is(raw_is("/f", XMETA, after, 402), 1, "netatalk: the blob is kept, its Finder Info zeroed");
	is(lklfuse_removexattr("/f", XFI), -HOST_ENOATTR, "netatalk: a second removexattr: ENOATTR");
	/* Review Focus 5: a blob too short for its Finder Info is never read as one, nor written */
	plant("/short", "s");
	lkl_sys_setxattr("/short", XMETA, before, 100, 0);
	is(lklfuse_getxattr("/short", XFI, b, sizeof(b)), -HOST_ENOATTR, "blob_short: getxattr FinderInfo: ENOATTR");
	is(listed("/short", XFI, 0), 0, "blob_short: not listed");
	is(lklfuse_setxattr("/short", XFI, fi_new, 32, 0), -EIO, "blob_short: setxattr FinderInfo: EIO");
	is(raw_is("/short", XMETA, before, 100), 1, "blob_short: the blob is unchanged");
	is(raw_has("/short", "user.com.apple.FinderInfo"), 0, "blob_short: and nothing was put beside it");
	xa_tag("/f");
	xa_leave(1);
}

static void xa_fruit_tests(void)
{
	char b[512], raw[512];
	long n;

	is(xa_enter(2), 0, "fruit image: mounted");
	is(lklfuse_xs_vol, XS_FRUIT_STREAM, "fruit image: the volume's scheme is fruit's streams");
	is(listed("/f", XFI, 0) + listed("/f", XTAGS, 0), 2, "listxattr_hides: the fruit file shows FinderInfo and the tag");
	is(listed("/f", "DosStream", 1) + listed("/f", "user.DosStream", 1) + listed("/f", "AFP_", 1), 0,
	   "listxattr_hides: never DosStream.*");
	is(fi_is("/f", fi_planted), 1, "fruit: getxattr FinderInfo reads AFP_AfpInfo's (offset 16)");
	n = lkl_sys_getxattr("/f", XTAGS_STREAM, raw, sizeof(raw));
	is(lklfuse_getxattr("/f", XTAGS, NULL, 0), (int)n - 1, "fruit: the tag's size is the stream's, less streams_xattr's 0 byte");
	is(lklfuse_getxattr("/f", XTAGS, b, sizeof(b)) == n - 1 && memcmp(b, raw, n - 1) == 0, 1, "fruit: and its bytes are the stream's");
	is(lklfuse_getxattr("/f", XTAGS, b, 2), -ERANGE, "fruit: a buffer too small: ERANGE");
	n = lkl_sys_getxattr("/f", XAFPI, raw, sizeof(raw));
	is(lklfuse_setxattr("/f", XFI, fi_new, 32, 0), 0, "fruit round trip: set FinderInfo");
	is(fi_is("/f", fi_new), 1, "fruit round trip: get it back");
	is((int)lkl_sys_getxattr("/f", XAFPI, b, sizeof(b)), 61, "fruit round trip: AFP_AfpInfo is still 60 bytes and the 0 byte");
	is(memcmp(b + 16, fi_new, 32), 0, "fruit round trip: stored in AFP_AfpInfo, at 16");
	is(n == 61 && memcmp(b, raw, 16) == 0 && memcmp(b + 48, raw + 48, 13) == 0, 1, "fruit round trip: the rest kept");
	is(raw_has("/f", "user.com.apple.FinderInfo") + raw_has("/f", XMETA), 0, "fruit round trip: no other carrier made");
	is(lklfuse_setxattr("/f", XTAGS, "tag2", 4, 0), 0, "fruit: change the tag");
	is(raw_is("/f", XTAGS_STREAM, "tag2", 5), 1, "fruit: in its stream, with the 0 byte");
	is(raw_has("/f", "user." XTAGS), 0, "fruit: and not as user.N");
	/* a new file: the volume's scheme */
	plant("/n", "n");
	is(lklfuse_setxattr("/n", XFI, fi_new, 32, 0), 0, "fruit: a new file's FinderInfo");
	n = lkl_sys_getxattr("/n", XAFPI, b, sizeof(b));
	is((int)n, 61, "fruit: makes AFP_AfpInfo, 60 bytes and the 0 byte");
	is(memcmp(b, "AFP\0\x00\x00\x01\x00\x00\x00\x00\x00\x80\x00\x00\x00", 16), 0, "fruit: signature, version, backup time never");
	is(memcmp(b + 16, fi_new, 32) == 0 && b[60] == 0, 1, "fruit: the FinderInfo at 16");
	is(lklfuse_setxattr("/n", XTAGS, "t", 1, 0), 0, "fruit: a new file's tag");
	is(raw_is("/n", XTAGS_STREAM, "t", 2), 1, "fruit: a stream named as the Mac's SMB client names it (':' as U+F022)");
	is(lklfuse_setxattr("/n", "k", "v", 1, 0), 0, "fruit: another new attribute");
	is(raw_is("/n", "user.DosStream.k:$DATA", "v", 2), 1, "fruit: user.DosStream.k:$DATA");
	is(listed("/n", "k", 0) + listed("/n", XTAGS, 0) + listed("/n", XFI, 0), 3, "fruit: all listed by their Mac names");
	is(lklfuse_removexattr("/n", "k"), 0, "fruit: removexattr of a stream");
	is(raw_has("/n", "user.DosStream.k:$DATA"), 0, "fruit: removes it");
	is(lklfuse_removexattr("/n", XFI), 0, "fruit: removexattr FinderInfo");
	is(raw_has("/n", XAFPI), 0, "fruit: removes AFP_AfpInfo, as Samba does for an all-zero one");
	/* a stream in more than one xattr (streams_xattr's last byte not 0) is never read as one, nor written */
	lkl_sys_setxattr("/f", "user.DosStream.big:$DATA", "ab\x01", 3, 0);
	is(listed("/f", "big", 0), 0, "fruit: a stream with extents is not listed");
	is(lklfuse_getxattr("/f", "big", b, sizeof(b)), -HOST_ENOATTR, "fruit: nor read");
	is(lklfuse_setxattr("/f", "big", "x", 1, 0), -EIO, "fruit: nor written");
	is(raw_is("/f", "user.DosStream.big:$DATA", "ab\x01", 3), 1, "fruit: and it is unchanged");
	xa_tag("/f");
	xa_leave(2);
}

static void xa_mixed_tests(void)
{
	char b[512];

	is(xa_enter(3), 0, "mixed image: mounted");
	is(lklfuse_xs_vol, XS_NETATALK, "mixed image: the volume's scheme is netatalk (its blob wins)");
	is(lklfuse_setxattr("/f", XFI, fi_new, 32, 0), 0, "mixed_follows_file: the netatalk file's FinderInfo");
	is(lkl_sys_getxattr("/f", XMETA, b, sizeof(b)) == 402 && memcmp(b + 122, fi_new, 32) == 0, 1,
	   "mixed_follows_file: is updated in its blob");
	is(raw_has("/f", "user.com.apple.FinderInfo") + raw_has("/f", XAFPI), 0, "mixed_follows_file: and nowhere else");
	is(lklfuse_setxattr("/o", XFI, fi_new, 32, 0), 0, "mixed_follows_file: the ours file's FinderInfo");
	is(raw_is("/o", "user.com.apple.FinderInfo", fi_new, 32) && !raw_has("/o", XMETA), 1, "mixed_follows_file: stays ours");
	is(lklfuse_setxattr("/s", XFI, fi_new, 32, 0), 0, "mixed_follows_file: the fruit file's FinderInfo");
	is(lkl_sys_getxattr("/s", XAFPI, b, sizeof(b)) == 61 && memcmp(b + 16, fi_new, 32) == 0 && !raw_has("/s", XMETA), 1,
	   "mixed_follows_file: stays in AFP_AfpInfo");
	plant("/n", "n");
	is(lklfuse_setxattr("/n", XFI, fi_new, 32, 0), 0, "mixed_follows_file: a new file's FinderInfo");
	is(lkl_sys_getxattr("/n", XMETA, b, sizeof(b)) == 402 && memcmp(b + 122, fi_new, 32) == 0, 1,
	   "mixed_follows_file: gets the volume's scheme (a netatalk blob)");
	xa_tag("/f");
	xa_tag("/o");
	xa_tag("/s");
	plant("/new", "new");
	xa_tag("/new");
	xa_leave(3);
}

static void xattr_tests(const char *dir)
{
	char *big;

	xname_tests();
	volume_scheme_tests();
	/* the oversized write: HFS+ refused only with ENOSPC (item-7-findings.md, push C), so lklfuse says that too */
	big = calloc(1, 131072);
	is(big && lklfuse_setxattr("/", "big", big, 131072, 0) == -ENOSPC, 1, "oversized: a 128 KiB setxattr: ENOSPC, HFS+'s refusal");
	free(big);
	is(dir != NULL, 1, "xattr images: the directory of tests/lib/xattr-images.sh's images was given");
	if (!dir)
		return;
	xa_ours_tests();
	xa_netatalk_tests();
	xa_fruit_tests();
	xa_mixed_tests();
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

	if (argc != 2 && argc != 3) {
		fprintf(stderr, "usage: lklfuse-ops-test EXT4-IMAGE [XATTR-IMAGE-DIR]\n");
		return 2;
	}
	lklfuse.file = argv[1];
	lklfuse.type = "ext4";
	lklfuse.disk.fd = lklfuse_open_disk();
	if (lklfuse.disk.fd < 0 || lkl_init(&lkl_host_ops) < 0)
		return 1;
	lklfuse.disk_id = lkl_disk_add(&lklfuse.disk);
#ifdef __APPLE__
	if (argc == 3)
		xa_add(argv[2]);
#endif
	if (lklfuse.disk_id < 0 || start_lkl())
		return 1;

	is(!!(fcntl(lklfuse.disk.fd, F_GETFD) & FD_CLOEXEC), 1, "the image is opened close-on-exec, so mount helpers do not inherit it");
	is(lklfuse_getattr("/missing", &(struct stat){ 0 }, NULL), -ENOENT, "getattr on a missing file: ENOENT");
	is(lklfuse_getxattr("/", "user.none", NULL, 0), -HOST_ENOATTR, "getxattr of a missing xattr: ENOATTR");
#ifdef __APPLE__
	/* patch 0013: a Mac name is stored as user.N, so com.apple.* no longer fails (it was EPERM through macFUSE) */
	is(lklfuse_setxattr("/", "com.apple.FinderInfo", "TEXTttxt\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0", 32, 0), 0,
	   "setxattr of a Mac name outside Linux's namespaces: stored");
	is(lkl_sys_getxattr("/", "user.com.apple.FinderInfo", NULL, 0), 32, "as user.com.apple.FinderInfo");
	is(lklfuse_removexattr("/", "com.apple.FinderInfo"), 0, "and removed");
#else
	is(lklfuse_setxattr("/", "com.apple.FinderInfo", "x", 1, 0), -ENOTSUP,
	   "setxattr outside Linux's namespaces: ENOTSUP, so macFUSE can fall back");
#endif
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
	volicon_tests();
	xattr_tests(argc == 3 ? argv[2] : NULL);
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

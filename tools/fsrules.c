/* The bundles' portable rules (see fsrules.h). Pure C99, libc only. */
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include "fsrules.h"

static const struct fsname names[] = {
	{ "ext4", "ext4", "macfuse_ext4", "ext4", "ext4", "Linux ext4 (linuxfs)", 7 },
	{ "ntfs", "ntfs3", "macfuse_ntfs", "ntfs", "NTFS-linuxfs", "Windows NTFS (linuxfs)", 8 },
	{ "btrfs", "btrfs", "macfuse_btrfs", "btrfs", "btrfs", "Linux btrfs (linuxfs)", 9 },
	{ "xfs", "xfs", "macfuse_xfs", "xfs", "XFS", "Linux XFS (linuxfs)", 10 },
	{ "f2fs", "f2fs", "macfuse_f2fs", "f2fs", "F2FS", "Linux F2FS (linuxfs)", 11 },
	{ "apfs", "apfs", "macfuse_apfs", "apfs", "APFS", "APFS (linuxfs)", 12 },
};
#define NNAMES (sizeof names / sizeof *names)

const struct fsname *fsrules_name_at(size_t i)
{
	return i < NNAMES ? &names[i] : NULL;
}

/* The entry whose fs is s[0..n), or NULL. */
static const struct fsname *known(const char *s, size_t n)
{
	size_t i;

	for (i = 0; s && i < NNAMES; i++)
		if (strlen(names[i].fs) == n && strncmp(names[i].fs, s, n) == 0)
			return &names[i];
	return NULL;
}

const struct fsname *fsrules_name(const char *fs)
{
	return fs ? known(fs, strlen(fs)) : NULL;
}

const char *fsrules_fs_of_type(const char *f_fstypename)
{
	size_t i;

	for (i = 0; f_fstypename && i < NNAMES; i++)
		if (strcmp(names[i].bundle, f_fstypename) == 0)
			return names[i].fs;
	return NULL;
}

int fsrules_mount_is_roots(const char *fs, const char *bsd, const char *f_fstypename, const char *f_mntfromname, unsigned owner)
{
	const char *t = fsrules_fs_of_type(f_fstypename);

	return fs && bsd && f_mntfromname && t && strcmp(t, fs) == 0 && owner == 0 && strncmp(f_mntfromname, "/dev/", 5) == 0 &&
	       strcmp(f_mntfromname + 5, bsd) == 0;
}

const char *fsrules_fs_from_name(const char *argv0, enum fsrole *role)
{
	const struct fsname *s;
	enum fsrole r;
	const char *b;
	size_t n;

	if (!argv0)
		return NULL;
	b = strrchr(argv0, '/');
	b = b ? b + 1 : argv0;
	n = strlen(b);
	if (strncmp(b, "mount_macfuse_", 14) == 0) {
		s = known(b + 14, n - 14);
		r = FS_MOUNT;
	} else if (strncmp(b, "fsck_macfuse_", 13) == 0) {
		s = known(b + 13, n - 13);
		r = FS_FSCK;
	} else if (strncmp(b, "macfuse_", 8) == 0 && n > 8 + 5 && strcmp(b + n - 5, ".util") == 0) {
		s = known(b + 8, n - 8 - 5);
		r = FS_UTIL;
	} else
		return NULL;
	if (s && role)
		*role = r;
	return s ? s->fs : NULL;
}

const char *fsrules_probe_type(const char *fs)
{
	return strcmp(fs, "ntfs") == 0 ? "ntfs3" : fs;
}

void fsrules_default_prefs(struct fsprefs *p)
{
	p->readonly = 0;
	p->ntfs_takeover = 0;
	p->apfs_write = 0;
}

int fsrules_claims(const char *fs, const char *probed_type, int removable, const struct fsprefs *p)
{
	if (!fs || !probed_type || !p || !fsrules_name(fs))
		return 0;
	if (strcmp(fs, "ntfs") == 0)
		return strcmp(probed_type, "ntfs3") == 0 && p->ntfs_takeover && removable;
	return strcmp(fs, probed_type) == 0;
}

unsigned fsrules_probe_flags(const char *fusion, const char *words)
{
	unsigned f = fusion && strncmp(fusion, "fusion-", 7) == 0 ? FSF_FUSION : 0;

	while (words && *words) {
		size_t n = strcspn(words, " ");

		if (n == 9 && strncmp(words, "encrypted", 9) == 0)
			f |= FSF_ENCRYPTED;
		else if (n == 5 && strncmp(words, "dirty", 5) == 0)
			f |= FSF_DIRTY;
		words += n;
		while (*words == ' ')
			words++;
	}
	return f;
}

enum fsaccess fsrules_access(const char *probed_type, unsigned flags, int ro, int before_login, const struct fsprefs *p,
			     const char **why)
{
	const char *w = "";
	enum fsaccess a = FSA_RO;

	if (!probed_type || !p)
		w = "", a = FSA_REFUSE;
	else if (before_login && (flags & FSF_ENCRYPTED))
		w = "encrypted", a = FSA_REFUSE;
	else if (ro)
		w = "asked";
	else if (p->readonly)
		w = "ReadOnly";
	else if (flags & FSF_ENCRYPTED)
		w = "encrypted";
	else if (strcmp(probed_type, "apfs") == 0 && (flags & FSF_FUSION))
		w = "fusion";
	else if (strcmp(probed_type, "apfs") == 0 && !p->apfs_write)
		w = "apfs";
	else if (strcmp(probed_type, "ntfs3") == 0 && (flags & FSF_DIRTY))
		w = "dirty";
	else
		a = FSA_RW;
	if (why)
		*why = w;
	return a;
}

/* LIST's next option, N bytes long, is exactly WORD */
static int opt_is(const char *list, size_t n, const char *word)
{
	return n == strlen(word) && strncmp(list, word, n) == 0;
}

static void options(const char *list, struct mountreq *m)
{
	while (*list) {
		size_t n = strcspn(list, ",");

		if (opt_is(list, n, "rdonly") || opt_is(list, n, "ro"))
			m->ro = 1;
		else if (opt_is(list, n, "owners") || opt_is(list, n, "perm"))
			m->owners = 1;
		else if (opt_is(list, n, "noowners") || opt_is(list, n, "noperm"))
			m->owners = 0;
		else if (opt_is(list, n, "update"))
			m->update = 1;
		list += n;
		if (*list == ',')
			list++;
	}
}

int fsrules_parse_mount(int argc, char **argv, struct mountreq *m)
{
	int i = 0, pos = 0;

	m->ro = m->owners = m->update = 0;
	m->dev = m->mnt = NULL;
	for (; i < argc; i++) {
		if (strcmp(argv[i], "-o") == 0) {
			if (++i >= argc)
				return -1;
			options(argv[i], m);
		} else if (strncmp(argv[i], "-o", 2) == 0) {
			options(argv[i] + 2, m);
		} else if (argv[i][0] == '-') {
			return -1;
		} else if (pos == 0) {
			m->dev = argv[i]; pos++;
		} else if (pos == 1) {
			m->mnt = argv[i]; pos++;
		} else {
			return -1;
		}
	}
	return pos == 2 ? 0 : -1;
}

/* The length of the UTF-8 character at s (strictly valid: no overlong forms, surrogates or above U+10FFFF), or 0. */
static int u8len(const unsigned char *s)
{
	if (s[0] < 0x80)
		return 1;
	if (s[0] >= 0xc2 && s[0] <= 0xdf)
		return (s[1] & 0xc0) == 0x80 ? 2 : 0;
	if (s[0] >= 0xe0 && s[0] <= 0xef) {
		if ((s[1] & 0xc0) != 0x80 || (s[2] & 0xc0) != 0x80)
			return 0;
		if (s[0] == 0xe0 && s[1] < 0xa0)
			return 0;
		if (s[0] == 0xed && s[1] > 0x9f)
			return 0;
		return 3;
	}
	if (s[0] >= 0xf0 && s[0] <= 0xf4) {
		if ((s[1] & 0xc0) != 0x80 || (s[2] & 0xc0) != 0x80 || (s[3] & 0xc0) != 0x80)
			return 0;
		if (s[0] == 0xf0 && s[1] < 0x90)
			return 0;
		if (s[0] == 0xf4 && s[1] > 0x8f)
			return 0;
		return 4;
	}
	return 0;
}

void fsrules_volname(const char *label, char *out, size_t outlen)
{
	const unsigned char *s = (const unsigned char *)label;
	size_t o = 0, chars = 0;
	int n;

	if (outlen == 0)
		return;
	if (s) {
		const unsigned char *v = s;

		while (*v) {			/* all of it must be UTF-8, else the fallback */
			n = u8len(v);
			if (!n) {
				v = NULL;
				break;
			}
			v += n;
		}
		s = v ? s : NULL;
	}
	if (s) {
		while (*s == '.')
			s++;
		while (*s && chars < 200) {
			n = u8len(s);
			if (o + n + 1 > outlen)
				break;
			if (n == 1 && (*s < 0x20 || *s == 0x7f || strchr("/:,=\\", *s)))
				out[o++] = '-';
			else
				memcpy(out + o, s, n), o += n;
			s += n;
			chars++;
		}
	}
	out[o] = 0;
	if (o == 0)
		strncpy(out, "Linux", outlen - 1), out[outlen - 1] = 0;
}

int fsrules_hint(const char *err, char *hint, size_t len)
{
	const char *p = NULL, *s = err, *q, *e;
	size_t o = 0;
	int n;

	while ((q = strstr(s, "(hint: "))) {
		p = q + 7;
		s = p;
	}
	if (!p || !len)
		return 0;
	e = strchr(p, '\n');
	if (!e)
		e = p + strlen(p);
	if (e > p && e[-1] == ')')
		e--;
	while (p + o < e) {
		n = u8len((const unsigned char *)p + o);
		if (!n || p + o + n > e)
			return 0;	/* not UTF-8: no hint at all */
		o += (size_t)n;
	}
	for (o = 0; p + o < e && (n = u8len((const unsigned char *)p + o)) && o + (size_t)n < len; o += (size_t)n)
		;
	memcpy(hint, p, o);
	hint[o] = '\0';
	return 1;
}

int fsrules_valid_bsd(const char *s)
{
	const char *q = s;

	if (strncmp(q, "disk", 4) != 0)
		return 0;
	q += 4;
	if (!isdigit((unsigned char)*q))
		return 0;
	while (isdigit((unsigned char)*q))
		q++;
	if (*q == 's') {
		q++;
		if (!isdigit((unsigned char)*q))
			return 0;
		while (isdigit((unsigned char)*q))
			q++;
	}
	return *q == '\0' && q - s <= 32;
}

int fsrules_whole_disk(const char *bsd, char *out, size_t outlen)
{
	size_t n;

	if (!bsd || !out || !fsrules_valid_bsd(bsd))
		return 0;
	n = 4 + strspn(bsd + 4, "0123456789");
	if (n >= outlen)
		return 0;
	memcpy(out, bsd, n);
	out[n] = '\0';
	return 1;
}

int fsrules_from_disk(const char *f_mntfromname, const char *whole)
{
	const char *r;
	size_t n;

	if (!f_mntfromname || !whole || strncmp(f_mntfromname, "/dev/", 5) != 0)
		return 0;
	n = strlen(whole);
	if (n == 0 || strncmp(f_mntfromname + 5, whole, n) != 0)
		return 0;
	r = f_mntfromname + 5 + n;
	if (*r == '\0')
		return 1;
	if (*r++ != 's' || !isdigit((unsigned char)*r))
		return 0;
	while (isdigit((unsigned char)*r))
		r++;
	return *r == '\0';
}

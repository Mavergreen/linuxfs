/* The bundles' portable rules (see fsrules.h). Pure C99, libc only. */
#include <stdio.h>
#include <string.h>
#include "fsrules.h"

static const char *const filesystems[] = { "ext4", "btrfs", "xfs", "f2fs", "apfs", "ntfs" };

/* The entry of `filesystems` that is s[0..n), or NULL. */
static const char *known(const char *s, size_t n)
{
	size_t i;

	for (i = 0; i < sizeof filesystems / sizeof *filesystems; i++)
		if (strlen(filesystems[i]) == n && strncmp(filesystems[i], s, n) == 0)
			return filesystems[i];
	return NULL;
}

const char *fsrules_fs_from_name(const char *argv0, enum fsrole *role)
{
	const char *b, *s;
	enum fsrole r;
	size_t n;

	if (!argv0)
		return NULL;
	b = strrchr(argv0, '/');
	b = b ? b + 1 : argv0;
	n = strlen(b);
	if (strncmp(b, "mount_linuxfs_", 14) == 0) {
		s = known(b + 14, n - 14);
		r = FS_MOUNT;
	} else if (strncmp(b, "fsck_linuxfs_", 13) == 0) {
		s = known(b + 13, n - 13);
		r = FS_FSCK;
	} else if (strncmp(b, "linuxfs_", 8) == 0 && n > 8 + 5 && strcmp(b + n - 5, ".util") == 0) {
		s = known(b + 8, n - 8 - 5);
		r = FS_UTIL;
	} else
		return NULL;
	if (s && role)
		*role = r;
	return s;
}

const char *fsrules_probe_type(const char *fs)
{
	return strcmp(fs, "ntfs") == 0 ? "ntfs3" : fs;
}

void fsrules_default_prefs(struct fsprefs *p)
{
	p->automount = 1;
	p->readonly = 0;
	p->ntfs_takeover = 0;
	p->apfs_write = 0;
}

int fsrules_claims(const char *fs, const char *probed_type, int removable, const struct fsprefs *p)
{
	if (!fs || !probed_type || !p || !known(fs, strlen(fs)))
		return 0;
	if (strcmp(fs, "ntfs") == 0)
		return strcmp(probed_type, "ntfs3") == 0 && p->ntfs_takeover && p->automount && removable;
	return strcmp(fs, probed_type) == 0;
}

static void options(const char *list, struct mountreq *m)
{
	while (*list) {
		size_t n = strcspn(list, ",");

		if (n == 6 && strncmp(list, "owners", 6) == 0)
			m->asked = 1;
		else if ((n == 6 && strncmp(list, "rdonly", 6) == 0) || (n == 2 && strncmp(list, "ro", 2) == 0))
			m->ro = 1;
		list += n;
		if (*list == ',')
			list++;
	}
}

int fsrules_parse_mount(int argc, char **argv, struct mountreq *m)
{
	int i = 0, pos = 0;

	m->asked = m->ro = 0;
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

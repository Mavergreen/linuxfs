/* linuxfs's /etc/fstab entries (see fstab.h). Pure C99, libc only, with fsrules.c for the filesystems' names. */
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include "fsrules.h"
#include "fstab.h"

#define TAG "# linuxfs"
#define LABEL_MAX 1000

const char *fstab_spec_refusal(const char *spec)
{
	const unsigned char *s;
	size_t i;

	if (!spec)
		return "no volume named";
	if (strncmp(spec, "UUID=", 5) == 0) {
		s = (const unsigned char *)spec + 5;
		for (i = 0; i < 36; i++) {
			if (i == 8 || i == 13 || i == 18 || i == 23) {
				if (s[i] != '-')
					return "a UUID must be uppercase 8-4-4-4-12 hexadecimal";
			} else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'A' && s[i] <= 'F'))) {
				return "a UUID must be uppercase 8-4-4-4-12 hexadecimal";
			}
		}
		return s[36] == '\0' ? NULL : "a UUID must be uppercase 8-4-4-4-12 hexadecimal";
	}
	if (strncmp(spec, "LABEL=", 6) == 0) {
		s = (const unsigned char *)spec + 6;
		if (!*s)
			return "an empty label names no volume";
		if (strlen((const char *)s) > LABEL_MAX)
			return "the label is too long";
		for (; *s; s++) {
			if (*s == '\n')
				return "a label with a newline cannot be written to /etc/fstab";
			if (*s == '#')
				return "a label with # cannot be written to /etc/fstab";
			if (*s == '\\')
				return "a label with a backslash cannot be written to /etc/fstab";
			if ((*s < 0x20 && *s != '\t') || *s == 0x7f)
				return "a label with a control character cannot be written to /etc/fstab";
		}
		return NULL;
	}
	return "a volume is named by UUID= or LABEL=";
}

const char *fstab_bundle_refusal(const char *bundle)
{
	size_t i;

	/* fsrules' table names the six, exactly: no prefix is matched as a family */
	for (i = 0; bundle && fsrules_name_at(i); i++)
		if (strcmp(bundle, fsrules_name_at(i)->bundle) == 0)
			return NULL;
	return "not a linuxfs bundle (macfuse_ext4, _btrfs, _xfs, _f2fs, _apfs or _ntfs)";
}

const char *fstab_bundle_for(const char *probe_type)
{
	size_t i;

	for (i = 0; probe_type && fsrules_name_at(i); i++)
		if (strcmp(probe_type, fsrules_name_at(i)->probe_type) == 0)
			return fsrules_name_at(i)->bundle;
	return NULL;
}

int fstab_escape(const char *spec, char *out, size_t outlen)
{
	size_t o = 0;
	const char *s;

	if (fstab_spec_refusal(spec))
		return -1;
	for (s = spec; *s; s++) {
		const char *piece = *s == ' ' ? "\\040" : *s == '\t' ? "\\011" : NULL;
		size_t n = piece ? 4 : 1;

		if (o + n + 1 > outlen)
			return -1;
		if (piece)
			memcpy(out + o, piece, 4);
		else
			out[o] = *s;
		o += n;
	}
	out[o] = '\0';
	return 0;
}

/* Whether line [p, e) (no newline) is linuxfs's, with first field ESPEC (NULL: any): a first field that is not a comment,
 * and the tag after a space or tab at the end, before an optional \r. */
static int ours(const char *p, const char *e, const char *espec)
{
	size_t t = strlen(TAG), n;
	const char *f;

	if (e > p && e[-1] == '\r')	/* an fstab edited on Windows */
		e--;
	if ((size_t)(e - p) < t + 1 || memcmp(e - t, TAG, t) != 0 || (e[-t - 1] != ' ' && e[-t - 1] != '\t'))
		return 0;
	while (p < e && (*p == ' ' || *p == '\t'))
		p++;
	for (f = p; f < e && *f != ' ' && *f != '\t'; f++)
		;
	if (f == p || *p == '#')	/* no first field: only the tag, perhaps indented (a comment) */
		return 0;
	if (!espec)
		return 1;
	n = strlen(espec);
	return (size_t)(f - p) == n && memcmp(p, espec, n) == 0;
}

/* Calls line(p, e, ctx) for each line of IN; stops at the first that returns nonzero, and returns it. */
static int each_line(const char *in, size_t len, int (*line)(const char *, const char *, void *), void *ctx)
{
	const char *p = in, *end = in + len, *e;
	int r;

	while (p < end) {
		e = memchr(p, '\n', (size_t)(end - p));
		if (!e)
			e = end;
		if ((r = line(p, e, ctx)) != 0)
			return r;
		p = e < end ? e + 1 : end;
	}
	return 0;
}

long fstab_edit(const char *in, size_t len, const char *spec, const char *bundle, char *out, size_t cap, int *changed)
{
	char espec[LABEL_MAX * 4 + 16], entry[sizeof espec + 64];
	const char *p = in, *end = in + len, *e, *next;
	size_t o = 0, n, elen = 0;
	int have = 0, removed = 0;

	*changed = 0;
	if (cap == 0 || (!spec && bundle) || (spec && fstab_escape(spec, espec, sizeof espec) != 0) ||
	    (bundle && fstab_bundle_refusal(bundle)))
		return -1;
	if (bundle) {
		snprintf(entry, sizeof entry, "%s none %s rw,noauto %s", espec, bundle, TAG);
		elen = strlen(entry);
	}
	if (cap > FSTAB_MAX + 1)
		cap = FSTAB_MAX + 1;	/* so the result never exceeds FSTAB_MAX */
	while (p < end) {
		e = memchr(p, '\n', (size_t)(end - p));
		next = e ? e + 1 : end;
		if (!e)
			e = end;
		if (ours(p, e, spec ? espec : NULL)) {
			if (bundle && !have && ((size_t)(e - p) == elen || ((size_t)(e - p) == elen + 1 && e[-1] == '\r')) &&
			    memcmp(p, entry, elen) == 0) {
				have = 1;	/* the very line: kept where it is */
			} else {
				removed = 1;
				p = next;
				continue;
			}
		}
		n = (size_t)(next - p);
		if (o + n > cap - 1)
			return -1;
		memcpy(out + o, p, n);
		o += n;
		p = next;
	}
	if (bundle && !have) {
		if (o > 0 && out[o - 1] != '\n') {
			if (o + 1 > cap - 1)
				return -1;
			out[o++] = '\n';
		}
		if (o + elen + 1 > cap - 1)
			return -1;
		memcpy(out + o, entry, elen);
		o += elen;
		out[o++] = '\n';
	}
	*changed = removed || (bundle && !have);
	return (long)o;
}

struct lookup { char uuid[48], label[LABEL_MAX * 4 + 16]; };

static int match(const char *p, const char *e, void *ctx)
{
	struct lookup *l = ctx;
	const char *f;

	if (!ours(p, e, NULL))
		return 0;
	while (p < e && (*p == ' ' || *p == '\t'))
		p++;
	for (f = p; f < e && *f != ' ' && *f != '\t'; f++)
		;
	if (l->uuid[0] && (size_t)(f - p) == strlen(l->uuid)) {
		size_t i;

		for (i = 0; p + i < f && toupper((unsigned char)p[i]) == toupper((unsigned char)l->uuid[i]); i++)
			;
		if (p + i == f)
			return 1;
	}
	return l->label[0] && (size_t)(f - p) == strlen(l->label) && memcmp(p, l->label, (size_t)(f - p)) == 0;
}

int fstab_has_noauto(const char *in, size_t len, const char *uuid, const char *volname)
{
	struct lookup l;
	char spec[LABEL_MAX + 16];

	l.uuid[0] = l.label[0] = '\0';
	if (uuid && *uuid && strlen(uuid) < sizeof l.uuid - 5)
		snprintf(l.uuid, sizeof l.uuid, "UUID=%s", uuid);
	if (volname && *volname && strlen(volname) <= LABEL_MAX) {
		snprintf(spec, sizeof spec, "LABEL=%s", volname);
		if (fstab_escape(spec, l.label, sizeof l.label) != 0)
			l.label[0] = '\0';
	}
	return (l.uuid[0] || l.label[0]) && each_line(in, len, match, &l);
}

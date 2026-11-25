/*
 * dev.mavergreen.linuxfs.mountd, the root mount daemon: its judging functions (mountd.h). They decide from facts the
 * daemon gathers and change nothing. The daemon's main (16h) is built only without LINUXFS_MOUNTD_NO_MAIN; the tests
 * (tests/mountd-test.sh) define it and link these with tools/helper.c (LINUXFS_HELPER_NO_MAIN), for its media rule.
 */
#include "mountd.h"
#include <stdio.h>
#include <string.h>

/* tools/helper.c: why a partition must not be handed out, from what it is; NULL when it may */
const char *helper_media_refusal(const char *content, int leaf, int ejectable, const char *fstype, int rw);

#define MOUNTD_REQ_MAX 1024
#define VOLUMES "/Volumes/"
#define MOUNTD_NAME_MAX 255	/* NAME_MAX: a longer name could never be opened */

/* field F (N bytes) into OUT (LEN bytes) as a string: 1, or 0 when it does not fit */
static int field(char *out, size_t len, const char *f, size_t n)
{
	if (n >= len)
		return 0;
	memcpy(out, f, n);
	out[n] = '\0';
	return 1;
}

int mountd_parse(const char *buf, size_t len, struct mountd_req *r, const char **why)
{
	static const char *const flags[] = { "-", "ro", "owners", "ro,owners", "owners,ro" };
	struct mountd_req q;
	const char *f[5], *p, *end, *name;
	size_t n[5], i, nlen;
	int k;

	memset(&q, 0, sizeof(q));
	*why = "a request is one line of at most 1024 bytes";
	if (!buf || len == 0 || len > MOUNTD_REQ_MAX || memchr(buf, '\0', len) || buf[len - 1] != '\n' ||
	    memchr(buf, '\n', len - 1))
		return -1;
	end = buf + len - 1;
	*why = "a request is mount<TAB>FS<TAB>BSD<TAB>FLAGS<TAB>MNT";
	for (p = buf, i = 0; i < 5; i++) {
		const char *t = i < 4 ? memchr(p, '\t', (size_t)(end - p)) : end;

		if (!t)
			return -1;
		f[i] = p;
		n[i] = (size_t)(t - p);
		p = t + (i < 4);
	}
	if (memchr(f[4], '\t', n[4]) || n[0] != 5 || memcmp(f[0], "mount", 5) != 0)
		return -1;
	*why = "not a filesystem linuxfs mounts";
	if (!field(q.fs, sizeof(q.fs), f[1], n[1]) || !fsrules_name(q.fs))
		return -1;
	*why = "not a BSD disk name";
	if (!field(q.bsd, sizeof(q.bsd), f[2], n[2]) || !fsrules_valid_bsd(q.bsd))
		return -1;
	*why = "the flags are -, ro, owners, ro,owners or owners,ro";
	for (k = 0; k < 5; k++)
		if (n[3] == strlen(flags[k]) && memcmp(f[3], flags[k], n[3]) == 0)
			break;
	if (k == 5)
		return -1;
	q.ro = k == 1 || k == 3 || k == 4;
	q.owners = k >= 2;
	*why = "the mount point is /Volumes/ and one name, with no control characters";
	if (!field(q.mnt, sizeof(q.mnt), f[4], n[4]) || strncmp(q.mnt, VOLUMES, strlen(VOLUMES)) != 0)
		return -1;
	name = q.mnt + strlen(VOLUMES);
	nlen = strlen(name);
	if (nlen == 0 || nlen > MOUNTD_NAME_MAX || strchr(name, '/') || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
		return -1;
	for (i = 0; i < nlen; i++)
		if ((unsigned char)name[i] < 0x20 || (unsigned char)name[i] == 0x7f)
			return -1;
	*r = q;
	*why = "";
	return 0;
}

enum mountd_peer mountd_peer(uid_t peer, uid_t console)
{
	if (peer == 0)
		return MP_ROOT;
	return peer == console ? MP_SERVE : MP_USER;
}

enum mountd_verdict mountd_judge(const struct mountd_req *r, const struct mountd_disk *d, uid_t peer, const char *type,
				 unsigned flags, const struct fsprefs *p, int mounted_bsd, int mounted_mnt, int *rc, const char **why)
{
	const struct fsname *n = fsrules_name(r->fs);
	const char *media;

	*rc = 1;
#define REFUSE(w) do { *why = (w); return MD_REFUSE; } while (0)
	/* root mounts by itself (the peer check answers it before judging; this keeps "an image only the peer's" true for 0) */
	if (peer == 0)
		REFUSE("root mounts by itself");
	/* 1. DiskArbitration's facts */
	if (!n)
		REFUSE("not a filesystem linuxfs mounts");
	if (strcmp(d->bsd, r->bsd) != 0)
		REFUSE("DiskArbitration described another disk");
	if (strcmp(d->kind, n->bundle) != 0)
		REFUSE("DiskArbitration has not given the disk to this filesystem's bundle");
	if (d->has_path)
		REFUSE("DiskArbitration has the disk mounted already");
	if (!d->leaf)
		REFUSE("a disk with partitions under it");
	/* 2. whose disk it is: the Mac's or the peer's, and an image only the peer's. Nothing is touched, so the user's own
	 * path is safe, and there the helper's owner rule still holds */
	if (!fsrules_node_owner_ok(d->node_uid, peer) || (d->image && d->node_uid != peer)) {
		*rc = 0;
		*why = "not your disk: your own mount";
		return MD_USER;
	}
	/* 3. the helper's media rule */
	if ((media = helper_media_refusal(d->content, d->leaf, d->ejectable, type, !r->ro)))
		REFUSE(media);
	/* 4. the mount table */
	if (mounted_bsd || mounted_mnt)
		REFUSE("something is mounted on the mount point or from the disk already");
	/* 5. the probe */
	if (!type || strcmp(type, fsrules_probe_type(r->fs)) != 0)
		REFUSE("the disk does not hold the filesystem asked for");
	if (!fsrules_claims(r->fs, type, d->removable, p)) {
		*rc = 3;
		REFUSE("the preferences say not to");
	}
#undef REFUSE
	*rc = 0;
	if (flags & FSF_ENCRYPTED) {
		*why = "encrypted";
		return MD_USER;
	}
	*why = "";
	return MD_MOUNT;
}

int mountd_mnt_facts(const struct stat *opened, const struct stat *entry, const struct stat *volumes, int empty, uid_t peer,
		     int *adopt, const char **why)
{
	if (!S_ISDIR(opened->st_mode) || !S_ISDIR(entry->st_mode))
		*why = "the mount point is not a directory";
	else if (opened->st_dev != entry->st_dev || opened->st_ino != entry->st_ino)
		*why = "the mount point changed";
	else if (opened->st_dev != volumes->st_dev)
		*why = "the mount point is not on /Volumes's volume";
	else if (!empty)
		*why = "the mount point is not empty";
	else if (opened->st_uid != 0 && (peer == 0 || opened->st_uid != peer))
		*why = "the mount point is another user's";
	else {
		*adopt = opened->st_uid != 0;
		*why = "";
		return 0;
	}
	return -1;
}

int mountd_adopted(const struct stat *after, const struct stat *entry_after, int empty_after, uid_t peer, const char **why)
{
	(void)peer;	/* on -1 the caller gives the directory back to the peer */
	if (!S_ISDIR(after->st_mode) || after->st_uid != 0 || (after->st_mode & 07777) != 0755 ||
	    after->st_dev != entry_after->st_dev || after->st_ino != entry_after->st_ino || !empty_after) {
		*why = "the mount point changed";
		return -1;
	}
	*why = "";
	return 0;
}

int mountd_rc(long rc)
{
	return rc >= 1 && rc <= 255 ? (int)rc : 1;
}

size_t mountd_reply(char *buf, size_t len, enum mountd_verdict v, int rc, const char *why)
{
	char head[16];
	const char *s;
	size_t n = 0;

	if (len < 2) {
		if (len)
			buf[0] = '\0';
		return 0;
	}
	if (v == MD_MOUNT) {
		snprintf(head, sizeof(head), "ok");
		why = NULL;
	} else if (v == MD_USER) {
		snprintf(head, sizeof(head), "user\t");
	} else {
		snprintf(head, sizeof(head), "no\t%d\t", mountd_rc(rc));
	}
	for (s = head; *s && n < len - 2; s++)
		buf[n++] = *s;
	for (s = why ? why : ""; *s && n < len - 2; s++)
		buf[n++] = (unsigned char)*s < 0x20 || (unsigned char)*s == 0x7f ? ' ' : *s;
	buf[n++] = '\n';
	buf[n] = '\0';
	return n;
}

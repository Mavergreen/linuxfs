/* Whether root may trust a file: the walk the mount program and the mount daemon run on what root runs or reads (trust.h). */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include "trust.h"

/* Whether a file or directory is owner's (root's) and writable by it alone (a group counts only when it is gid 0: /usr/local is
 * root:wheel 0775). A root-owned directory with the sticky bit counts whoever can write it: nobody else can rename or remove root's
 * entries, and the walk requires each entry below it to be root's too (stock 10.9 may ship / as 1775 root:admin). */
static int root_only(const struct stat *st, uid_t owner)
{
	if (st->st_uid != owner)
		return 0;
	if (S_ISDIR(st->st_mode) && (st->st_mode & S_ISVTX))
		return 1;
	return !(st->st_mode & S_IWOTH) && (!(st->st_mode & S_IWGRP) || st->st_gid == 0);
}

int trust_path(const char *path, uid_t owner, const char *trust_root, char *out, size_t outlen)
{
	char cur[PATH_MAX], rest[2 * PATH_MAX], trust[PATH_MAX], next[PATH_MAX], link[PATH_MAX], compbuf[NAME_MAX + 1];
	const char *tr = trust_root;
	struct stat st;
	size_t skip = 0, cn;
	int hops = 0;

	if (path[0] != '/' || strlen(path) >= sizeof rest)
		return -2;
	if (tr && !(realpath(tr, trust) && (skip = strlen(trust)) > 0))
		return -1;
	snprintf(rest, sizeof rest, "%s", path);
	cur[0] = '/';
	cur[1] = '\0';
	if (!skip && (lstat("/", &st) != 0 || !root_only(&st, owner)))
		return -1;
	for (;;) {
		char *r = rest, *slash;
		const char *comp;
		size_t cl = strlen(cur);

		while (*r == '/')
			r++;
		if (!*r)
			break;
		slash = strchr(r, '/');
		cn = slash ? (size_t)(slash - r) : strlen(r);
		if (cn >= sizeof compbuf)
			return -2;
		memcpy(compbuf, r, cn);
		compbuf[cn] = '\0';
		comp = compbuf;
		memmove(rest, r + cn, strlen(r + cn) + 1);
		if (strcmp(comp, ".") == 0)
			continue;
		if (strcmp(comp, "..") == 0) {
			while (cl > 1 && cur[cl - 1] != '/')
				cl--;
			if (cl > 1)
				cl--;
			cur[cl] = '\0';
			continue;
		}
		if ((size_t)snprintf(next, sizeof next, "%s%s%s", cur, cl > 1 ? "/" : "", comp) >= sizeof next)
			return -2;
		if (lstat(next, &st) != 0)
			return -2;
		if (S_ISLNK(st.st_mode)) {
			ssize_t n;
			size_t tl, rl;

			if (st.st_uid != owner && !(skip && strlen(next) <= skip))
				return -1;
			if (++hops > 16 || (n = readlink(next, link, sizeof link - 1)) <= 0)
				return -2;
			link[n] = '\0';
			tl = strlen(link);
			rl = strlen(rest);
			if (tl + 1 + rl >= sizeof rest)
				return -2;
			memmove(rest + tl + 1, rest, rl + 1);
			memcpy(rest, link, tl);
			rest[tl] = '/';
			if (link[0] == '/') {
				cur[0] = '/';
				cur[1] = '\0';
			}
			continue;
		}
		if (S_ISDIR(st.st_mode)) {
			if (strlen(next) > skip && !root_only(&st, owner))
				return -1;
			memcpy(cur, next, strlen(next) + 1);
			continue;
		}
		if (!S_ISREG(st.st_mode))
			return -2;
		/* a file ends the path */
		{
			char *e = rest;

			while (*e == '/')
				e++;
			if (*e)
				return -2;
		}
		if (!root_only(&st, owner))
			return -1;
		if (strlen(next) >= outlen)
			return -1;
		memcpy(out, next, strlen(next) + 1);
		return 0;
	}
	return -2;	/* the path ended on a directory */
}

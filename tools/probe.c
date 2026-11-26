/*
 * linuxfs-probe (and linuxfs_probe_fd, for linuxfs-helper): names the filesystem on a device or image by its superblock, as lklfuse's type= spells it.
 * usage: linuxfs-probe PATH
 *        linuxfs-probe --uuid PATH
 *        linuxfs-probe --access TYPE FUSION FLAGS [ro] [readonly] [apfs-write] [before-login]
 *        linuxfs-probe --groups
 * Prints "TYPE<TAB>LABEL" (the label empty where none is read), then a tab and the Fusion role, and a tab and the flags
 * (probe.h), when there are any; exits 0; prints "unknown" and exits 1 when no superblock it knows is there; exits 2 when
 * PATH cannot be read. Reads at most the first 68 KiB, and what an APFS or NTFS volume's name and flags need beyond it.
 * --access prints how a volume the probe described so (its third and fourth fields, "" when absent) mounts, by
 * fsrules_access, with the request (ro) and preferences (readonly: ReadOnly; apfs-write: APFSWrite) the words name:
 * "rw", "ro REASON" or "refuse REASON"; exits 2 on misuse. It is the CLI's way to the root mount program's rule.
 * --uuid prints the filesystem's UUID as linuxfs_probe_uuid gives it (what the bundles' util -k tells DiskArbitration)
 * and exits 0; exits 1, printing nothing, when there is none.
 * --groups prints the process's own groups (its credential's, which macFUSE judges allow_root by), decimal, space-separated, on
 * one line, and exits 0. On Darwin through the kernel's getgroups (_getgroups), never getgroups$DARWIN_EXTSN, which asks the
 * directory for the user's groups, as id -G prints them: a process DiskArbitration starts has not the user's groups.
 */
#include "probe.h"
#include "fsrules.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define SPAN (0x10000 + 0x1000)

static unsigned char buf[SPAN];
static size_t have;
static int probe_fd = -1;	/* for the reads beyond SPAN that an APFS volume's name needs */
static size_t uuid_off;		/* where the 16 UUID bytes sit in buf, or 0 when the filesystem has none */
static char extra[64];		/* a third field: an APFS Fusion device's role and container */
static char vflags[32];		/* a fourth: "encrypted", "dirty" */

const char *linuxfs_probe_extra(void)
{
	return extra;
}

const char *linuxfs_probe_flags(void)
{
	return vflags;
}

int linuxfs_probe_line(char *out, size_t len, const char *type, const char *label)
{
	int n;

	if (*vflags)
		n = snprintf(out, len, "%s\t%s\t%s\t%s", type, label, extra, vflags);
	else if (*extra)
		n = snprintf(out, len, "%s\t%s\t%s", type, label, extra);
	else
		n = snprintf(out, len, "%s\t%s", type, label);
	return n < 0 || (size_t)n >= len ? -1 : 0;
}


static int has(size_t off, size_t len)
{
	return off + len <= have;
}

static int is(size_t off, const char *magic, size_t len)
{
	return has(off, len) && memcmp(buf + off, magic, len) == 0;
}

static unsigned le16(size_t off)
{
	return buf[off] | buf[off + 1] << 8;
}

static uint32_t le32(size_t off)
{
	return (uint32_t)le16(off) | (uint32_t)le16(off + 2) << 16;
}

/* The length of the UTF-8 sequence at P (at most LEN bytes), or 0 if it is not one (review M5). */
static size_t utf8_len(const unsigned char *p, size_t len)
{
	size_t n, i;
	uint32_t c;

	if (p[0] < 0x80)
		return 1;
	if (p[0] >= 0xc2 && p[0] <= 0xdf)
		n = 2, c = p[0] & 0x1f;
	else if (p[0] >= 0xe0 && p[0] <= 0xef)
		n = 3, c = p[0] & 0x0f;
	else if (p[0] >= 0xf0 && p[0] <= 0xf4)
		n = 4, c = p[0] & 0x07;
	else
		return 0;
	if (n > len)
		return 0;
	for (i = 1; i < n; i++) {
		if ((p[i] & 0xc0) != 0x80)
			return 0;
		c = c << 6 | (p[i] & 0x3f);
	}
	if ((n == 3 && c < 0x800) || (n == 4 && (c < 0x10000 || c > 0x10ffff)) || (c >= 0xd800 && c <= 0xdfff))
		return 0;
	return n;
}

/* Appends code point C to OUT as UTF-8, if it fits whole. */
static void put_utf8(uint32_t c, char *out, size_t *n, size_t outlen)
{
	unsigned char b[4];
	size_t k;

	if (c < 0x20 || c == 0x7f || (c >= 0xd800 && c <= 0xdfff) || c > 0x10ffff)
		c = '?';
	if (c < 0x80)
		b[0] = c, k = 1;
	else if (c < 0x800)
		b[0] = 0xc0 | c >> 6, b[1] = 0x80 | (c & 0x3f), k = 2;
	else if (c < 0x10000)
		b[0] = 0xe0 | c >> 12, b[1] = 0x80 | (c >> 6 & 0x3f), b[2] = 0x80 | (c & 0x3f), k = 3;
	else
		b[0] = 0xf0 | c >> 18, b[1] = 0x80 | (c >> 12 & 0x3f), b[2] = 0x80 | (c >> 6 & 0x3f), b[3] = 0x80 | (c & 0x3f), k = 4;
	if (*n + k < outlen) {
		memcpy(out + *n, b, k);
		*n += k;
	}
}

static void trim(char *out, size_t n)
{
	while (n > 0 && out[n - 1] == ' ')
		n--;
	out[n] = '\0';
}

/* A label stored as bytes (UTF-8 by convention): NUL- or space-padded; a byte that does not begin a whole UTF-8
 * sequence, or a control character, becomes '?', and a sequence that does not fit is left out whole. */
static void label_bytes(const unsigned char *p, size_t len, char *out, size_t outlen)
{
	size_t i = 0, n = 0, k;

	while (i < len && p[i]) {
		k = utf8_len(p + i, len - i);
		if (k == 0 || (k == 1 && (p[i] < 0x20 || p[i] == 0x7f))) {
			put_utf8('?', out, &n, outlen);
			i++;
			continue;
		}
		if (n + k < outlen) {
			memcpy(out + n, p + i, k);
			n += k;
		}
		i += k;
	}
	trim(out, n);
}

/* A label stored as UTF-16LE (NTFS, exFAT, f2fs): UNITS code units at most, ending at a NUL. */
static void label_utf16(const unsigned char *p, size_t units, char *out, size_t outlen)
{
	size_t i, n = 0;

	for (i = 0; i < units; i++) {
		uint32_t c = p[2 * i] | p[2 * i + 1] << 8;

		if (c == 0)
			break;
		if (c >= 0xd800 && c <= 0xdbff && i + 1 < units) {
			uint32_t d = p[2 * i + 2] | p[2 * i + 3] << 8;

			if (d >= 0xdc00 && d <= 0xdfff) {
				c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
				i++;
			}
		}
		put_utf8(c, out, &n, outlen);
	}
	trim(out, n);
}

/* A fixed-size label field in the first SPAN bytes. */
static void label(size_t off, size_t len, char *out, size_t outlen)
{
	if (!has(off, len))
		len = have > off ? have - off : 0;
	label_bytes(buf + off, len, out, outlen);
}

static uint64_t get64(const unsigned char *b, size_t off)
{
	uint64_t v = 0;

	for (int i = 7; i >= 0; i--)
		v = v << 8 | b[off + i];
	return v;
}

static uint32_t get32(const unsigned char *b, size_t off)
{
	return (uint32_t)b[off] | (uint32_t)b[off + 1] << 8 | (uint32_t)b[off + 2] << 16 | (uint32_t)b[off + 3] << 24;
}

static int read_at(unsigned char *b, size_t len, uint64_t off)
{
	ssize_t r = probe_fd < 0 ? -1 : pread(probe_fd, b, len, (off_t)off);

	return r == (ssize_t)len ? 0 : -1;
}

static int read_block(unsigned char *b, uint32_t bs, uint64_t n)
{
	return read_at(b, bs, n * bs);
}

/*
 * NTFS's volume name: the $VOLUME_NAME attribute (0x60, resident, UTF-16LE) of MFT record 3 ($Volume). The boot
 * sector gives bytes per sector (0x0b), sectors per cluster (0x0d), the MFT's first cluster (0x30) and the record
 * size (0x40: clusters, or 2^-n bytes when negative). The record's update sequence (offset 0x04, count 0x06) puts
 * back each sector's last two bytes; attributes start at 0x14 and end at type 0xffffffff.
 */
static void ntfs_label(char *out, size_t outlen)
{
	uint32_t bps = le16(0x0b), spc = buf[0x0d], rs;
	int8_t cpr = (int8_t)buf[0x40];
	uint64_t mft = get64(buf, 0x30);
	unsigned char *r;
	size_t a;

	out[0] = '\0';
	if (bps < 256 || bps > 4096 || (bps & (bps - 1)) || !spc)
		return;
	rs = cpr < 0 ? (cpr < -16 ? 0 : 1u << -cpr) : (uint32_t)cpr * spc * bps;
	if (rs < 512 || rs > 65536 || !(r = malloc(rs)))
		return;
	if (read_at(r, rs, mft * spc * bps + 3ull * rs) < 0 || memcmp(r, "FILE", 4) != 0)
		goto done;
	{
		size_t uo = r[4] | r[5] << 8, uc = r[6] | r[7] << 8, i;

		if (uc < 1 || uo + 2 * uc > rs || (uc - 1) * bps > rs)
			goto done;
		for (i = 1; i < uc; i++) {
			memcpy(r + i * bps - 2, r + uo + 2 * i, 2);
		}
	}
	for (a = r[0x14] | r[0x15] << 8; a + 24 <= rs;) {
		uint32_t type = get32(r, a), len = get32(r, a + 4);

		if (type == 0xffffffff || len < 24 || a + len > rs)
			break;
		if (type == 0x60 && r[a + 8] == 0) {
			uint32_t vl = get32(r, a + 0x10);
			size_t vo = r[a + 0x14] | r[a + 0x15] << 8;

			if (vo + vl <= len)
				label_utf16(r + a + vo, vl / 2, out, outlen);
		}
		/* $VOLUME_INFORMATION (resident): its flags at 10 in the value; VOLUME_IS_DIRTY is 1, what ntfs3 refuses to write */
		if (type == 0x70 && r[a + 8] == 0) {
			uint32_t vl = get32(r, a + 0x10);
			size_t vo = r[a + 0x14] | r[a + 0x15] << 8;

			if (vl >= 12 && vo + 12 <= len && (r[a + vo + 10] & 1))
				snprintf(vflags, sizeof vflags, "dirty");
		}
		a += len;
	}
done:
	free(r);
}

/*
 * exFAT's volume label: the root directory's entry of type 0x83 (character count at 1, UTF-16LE name at 2, up to
 * 11 units). The boot sector gives the sector and cluster shifts (108, 109), the cluster heap's first sector (88)
 * and the root directory's first cluster (96); the label is looked for in that first cluster.
 */
static void exfat_label(char *out, size_t outlen)
{
	unsigned bss = buf[108], spcs = buf[109];
	uint64_t heap = le32(88), root = le32(96), cs;
	unsigned char *c;
	size_t e;

	out[0] = '\0';
	if (bss < 9 || bss > 12 || spcs > 25 - bss || root < 2)
		return;
	cs = (uint64_t)1 << (bss + spcs);
	if (cs > 1 << 20)
		cs = 1 << 20;	/* the label sits near the start; no need to read a huge cluster whole */
	if (!(c = malloc(cs)))
		return;
	if (read_at(c, cs, (heap << bss) + ((root - 2) << (bss + spcs))) == 0)
		for (e = 0; e + 32 <= cs && c[e]; e += 32)
			if (c[e] == 0x83) {
				label_utf16(c + e + 2, c[e + 1] > 11 ? 11 : c[e + 1], out, outlen);
				break;
			}
	free(c);
}

/*
 * APFS volume 0's name: the container's object map (a B-tree of virtual oid -> physical block) gives the block of
 * the volume superblock, which holds the name and whether the volume is encrypted. Apple's "Apple File System Reference" layouts: nx_superblock_t
 * (nx_block_size at 36, nx_omap_oid at 160, nx_fs_oid[] at 184), omap_phys_t (om_tree_oid at 48),
 * btree_node_phys_t (flags at 32, level at 34, nkeys at 36, table space at 40, entries from 56; a root node keeps a
 * 40-byte btree_info_t at its end), omap keys {oid, xid} and values {flags, size, paddr}, apfs_superblock_t ("APSB"
 * at 32, apfs_fs_flags at 264, whose APFS_FS_UNENCRYPTED (1) clear is what linux-apfs-rw asks a password for,
 * apfs_volname at 704). Leaves the label empty, and the flags, on anything unexpected.
 */
static void apfs_label(char *out, size_t outlen)
{
	uint32_t bs = le32(36);
	uint64_t want = get64(buf, 184), node, best;
	unsigned char *b;
	int depth;

	out[0] = '\0';
	if (probe_fd < 0 || bs < 4096 || bs > 65536 || (bs & (bs - 1)) || !want || !(b = malloc(bs)))
		return;
	if (read_block(b, bs, get64(buf, 160)) < 0)
		goto done;
	node = get64(b, 48);
	for (depth = 0; depth < 8; depth++) {
		unsigned flags, level, toff, tlen, nkeys, i;
		size_t keys, vend;

		if (read_block(b, bs, node) < 0)
			goto done;
		flags = b[32] | b[33] << 8;
		level = b[34] | b[35] << 8;
		nkeys = get32(b, 36);
		toff = b[40] | b[41] << 8;
		tlen = b[42] | b[43] << 8;
		if (!(flags & 4) || 56 + toff + tlen > bs || nkeys > tlen / 4)
			goto done;	/* omap trees use fixed-size keys and values */
		keys = 56 + toff + tlen;
		vend = (flags & 1) ? bs - 40 : bs;
		best = 0;
		for (i = 0; i < nkeys; i++) {
			size_t e = 56 + toff + 4 * i;
			size_t k = keys + (b[e] | b[e + 1] << 8), v = vend - (b[e + 2] | b[e + 3] << 8);
			uint64_t oid;

			if (k + 16 > bs || v + 16 > bs || v < keys)
				goto done;
			oid = get64(b, k);
			if (level == 0 && oid == want)
				best = get64(b, v + 8);		/* the latest xid comes last */
			else if (level > 0 && oid <= want)
				best = get64(b, v);		/* the child that may hold it */
		}
		if (!best)
			goto done;
		if (level == 0) {
			if (read_block(b, bs, best) == 0 && memcmp(b + 32, "APSB", 4) == 0) {
				label_bytes(b + 704, 256, out, outlen);
				if (!(b[264] & 1))
					snprintf(vflags, sizeof vflags, "encrypted");
			}
			goto done;
		}
		node = best;
	}
done:
	free(b);
}

static const char *probe(char *lab, size_t lablen)
{
	lab[0] = '\0';
	uuid_off = 0;
	/* APFS: a container (10.9 has no driver for it; linux-apfs-rw reads it), named by its first volume */
	if (has(0, 4096) && is(32, "NXSB", 4)) {
		/* nx_fusion_uuid (0x500): zero unless Fusion; the second device's has its lowest bit set */
		static const unsigned char zero[16];

		if (memcmp(buf + 0x500, zero, 16) != 0) {
			int tier2 = buf[0x50f] & 1;
			int n = snprintf(extra, sizeof(extra), "fusion-%s ", tier2 ? "tier2" : "main");

			for (int i = 0; i < 16; i++)
				n += snprintf(extra + n, sizeof(extra) - n, "%02x", i == 15 ? buf[0x500 + i] & 0xfe : buf[0x500 + i]);
			if (tier2)
				return "apfs";	/* its blocks are the main device's container's: no volume to name here */
		}
		uuid_off = 72;		/* nx_uuid */
		apfs_label(lab, lablen);
		return "apfs";
	}
	/* the Mac's own, whatever else the bytes suggest (review I5): HFS+/HFSX header */
	if (has(1024, 2) && (is(1024, "H+", 2) || is(1024, "HX", 2)))
		return NULL;
	/* ext: the magic, and superblock fields every ext2/3/4 has (block size 1-64 KiB, inodes per group,
	 * revision 0 or 1), so a stray 0xEF53 is not enough */
	if (has(1024, 1024) && le16(1024 + 56) == 0xEF53 && le32(1024 + 24) <= 6 && le32(1024 + 40) != 0 &&
	    le32(1024 + 76) <= 1) {
		uuid_off = 1024 + 0x68;	/* s_uuid */
		label(1024 + 120, 16, lab, lablen);
		return "ext4";
	}
	if (has(0x10000, 4096) && is(0x10040, "_BHRfS_M", 8)) {
		uuid_off = 0x10020;	/* fsid */
		label(0x1012b, 256, lab, lablen);
		return "btrfs";
	}
	if (has(0, 512) && is(0, "XFSB", 4)) {
		uuid_off = 32;		/* sb_uuid */
		label(108, 12, lab, lablen);
		return "xfs";
	}
	if (is(3, "NTFS    ", 8) && has(0, 512)) {
		ntfs_label(lab, lablen);
		return "ntfs3";
	}
	if (is(3, "EXFAT   ", 8) && has(0, 512)) {
		exfat_label(lab, lablen);
		return "exfat";
	}
	/* f2fs: uuid at 108 and volume_name, 512 UTF-16LE units, at 124 in the superblock (f2fs_super_block, include/linux/f2fs_fs.h) */
	if (has(1024, 2048) && le32(1024) == 0xF2F52010) {
		uuid_off = 1024 + 108;	/* uuid, just before volume_name */
		label_utf16(buf + 1024 + 124, 512, lab, lablen);
		return "f2fs";
	}
	if (has(0, 512) && buf[510] == 0x55 && buf[511] == 0xAA) {
		if (is(0x52, "FAT32   ", 8)) {
			label(0x47, 11, lab, lablen);
			return "vfat";
		}
		if (is(0x36, "FAT1", 4)) {
			label(0x2b, 11, lab, lablen);
			return "vfat";
		}
	}
	return NULL;
}

volatile sig_atomic_t *linuxfs_probe_stop;

const char *linuxfs_probe_fd(int fd, char *lab, size_t lablen, int *err)
{
	const char *type;
	ssize_t r;

	have = 0;
	uuid_off = 0;
	*err = 0;
	extra[0] = '\0';
	vflags[0] = '\0';
	while (have < SPAN) {
		r = pread(fd, buf + have, SPAN - have, have);
		if (r < 0 && errno == EINTR && !(linuxfs_probe_stop && *linuxfs_probe_stop))
			continue;
		if (r < 0) {
			*err = errno;
			return NULL;
		}
		if (r == 0)
			break;
		have += r;
	}
	probe_fd = fd;
	type = probe(lab, lablen);
	probe_fd = -1;
	if (type && strcmp(lab, "NO NAME") == 0)
		lab[0] = '\0';
	return type;
}

int linuxfs_probe_uuid(char *out, size_t outlen)
{
	static const char hex[] = "0123456789ABCDEF";
	static const unsigned char zero[16];
	size_t i, n = 0;

	/* has() is defence in depth: each type's own check already covers its UUID */
	if (!uuid_off || !has(uuid_off, 16) || outlen < 37 || memcmp(buf + uuid_off, zero, 16) == 0)
		return -1;
	for (i = 0; i < 16; i++) {
		if (i == 4 || i == 6 || i == 8 || i == 10)
			out[n++] = '-';
		out[n++] = hex[buf[uuid_off + i] >> 4];
		out[n++] = hex[buf[uuid_off + i] & 15];
	}
	out[n] = '\0';
	return 0;
}

#ifndef LINUXFS_PROBE_NO_MAIN
#ifdef __APPLE__
/* the kernel's getgroups(2): the process's credential, at most NGROUPS (16) groups; the SDK's getgroups is getgroups$DARWIN_EXTSN */
int kernel_getgroups(int, gid_t *) __asm("_getgroups");
#else
#define kernel_getgroups getgroups
#endif

static int print_groups(void)
{
	gid_t g[64];
	int i, n = kernel_getgroups((int)(sizeof g / sizeof g[0]), g);

	if (n < 0) {
		fprintf(stderr, "linuxfs-probe: getgroups: %s\n", strerror(errno));
		return 2;
	}
	for (i = 0; i < n; i++)
		printf("%s%lu", i ? " " : "", (unsigned long)g[i]);
	printf("\n");
	return 0;
}

int main(int argc, char **argv)
{
	char lab[512], uuid[40], line[700];
	const char *type, *path;
	int fd, err, want_uuid = argc == 3 && strcmp(argv[1], "--uuid") == 0;

	if (argc == 2 && strcmp(argv[1], "--groups") == 0)
		return print_groups();
	if (argc >= 5 && strcmp(argv[1], "--access") == 0) {
		static const char *const names[] = { "rw", "ro", "refuse" };
		struct fsprefs p;
		const char *why;
		int i, ro = 0, login = 0;
		enum fsaccess a;

		fsrules_default_prefs(&p);
		for (i = 5; i < argc; i++) {
			if (strcmp(argv[i], "ro") == 0)
				ro = 1;
			else if (strcmp(argv[i], "readonly") == 0)
				p.readonly = 1;
			else if (strcmp(argv[i], "apfs-write") == 0)
				p.apfs_write = 1;
			else if (strcmp(argv[i], "before-login") == 0)
				login = 1;
			else
				goto usage;
		}
		a = fsrules_access(argv[2], fsrules_probe_flags(argv[3], argv[4]), ro, login, &p, &why);
		printf("%s%s%s\n", names[a], *why ? " " : "", why);
		return 0;
	}
	if (argc != 2 && !want_uuid) {
usage:
		fprintf(stderr, "usage: linuxfs-probe PATH\n       linuxfs-probe --uuid PATH\n"
			"       linuxfs-probe --access TYPE FUSION FLAGS [ro] [readonly] [apfs-write] [before-login]\n"
			"       linuxfs-probe --groups\n");
		return 2;
	}
	path = argv[argc - 1];
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "linuxfs-probe: %s: %s\n", path, strerror(errno));
		return 2;
	}
	type = linuxfs_probe_fd(fd, lab, sizeof(lab), &err);
	close(fd);
	if (err) {
		fprintf(stderr, "linuxfs-probe: %s: %s\n", path, strerror(err));
		return 2;
	}
	if (want_uuid) {
		if (!type || linuxfs_probe_uuid(uuid, sizeof(uuid)) != 0)
			return 1;
		printf("%s\n", uuid);
		return 0;
	}
	if (!type) {
		printf("unknown\n");
		return 1;
	}
	if (linuxfs_probe_line(line, sizeof line, type, lab) != 0)
		return 2;
	printf("%s\n", line);
	return 0;
}
#endif

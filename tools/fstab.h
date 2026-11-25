/*
 * linuxfs's /etc/fstab entries: pure C99, libc only (with fsrules.c), so they build and test on any host. DiskArbitration
 * leaves a volume unmounted at plug-in when /etc/fstab has an entry for it with noauto, matched by UUID= (the volume UUID the
 * bundle's util prints for -k) or LABEL= (the volume name it prints for -p); `diskutil mount` and Disk Utility still mount it.
 * linuxfs writes one line per volume, and touches no other:
 *     <SPEC> none <BUNDLE> rw,noauto # linuxfs
 * A label's space is written \040 and its tab \011, as fstab spells them.
 */
#ifndef LINUXFS_FSTAB_H
#define LINUXFS_FSTAB_H

#include <stddef.h>

#define FSTAB_MAX (64 * 1024)	/* the largest /etc/fstab linuxfs reads or writes */

/* Why SPEC may not be written, or NULL when it may: UUID= and a canonical uppercase 8-4-4-4-12 UUID, or LABEL= and a
 * non-empty label of at most 1000 bytes with no newline, #, backslash, DEL or byte below 0x20 other than tab. */
const char *fstab_spec_refusal(const char *spec);

/* Why BUNDLE may not be written, or NULL when it may: macfuse_ext4, _btrfs, _xfs, _f2fs, _apfs or _ntfs. */
const char *fstab_bundle_refusal(const char *bundle);

/* The bundle for what tools/probe.c names a filesystem (ntfs3 is macfuse_ntfs), or NULL when no bundle mounts it. */
const char *fstab_bundle_for(const char *probe_type);

/* SPEC as fstab spells it (a label's space as \040, its tab as \011) into OUT; 0, or -1 when SPEC is refused or does not fit. */
int fstab_escape(const char *spec, char *out, size_t outlen);

/* IN (LEN bytes) with every linuxfs line for SPEC removed and, when BUNDLE is not NULL, SPEC's line added at the end; when
 * that line is already there, IN is kept as it is. Every other line is kept byte for byte. The result goes to OUT (CAP
 * bytes) and its length is returned, *changed saying whether it differs from IN; -1 when SPEC or BUNDLE is refused or the
 * result is over FSTAB_MAX or CAP. With SPEC and BUNDLE both NULL, every linuxfs line goes (uninstall). */
long fstab_edit(const char *in, size_t len, const char *spec, const char *bundle, char *out, size_t cap, int *changed);

/* Whether IN (LEN bytes) has a linuxfs line for UUID= UUID (any case) or LABEL= VOLNAME; either may be NULL or empty. */
int fstab_has_noauto(const char *in, size_t len, const char *uuid, const char *volname);

#endif

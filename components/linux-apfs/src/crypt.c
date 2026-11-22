// SPDX-License-Identifier: GPL-2.0-only
/*
 * Reading a software-encrypted APFS volume, read-only: linuxfs's addition to linux-apfs-rw (see unlock.h).
 *
 * At mount, the password (mount option pass=, hex) unlocks the volume key. Then:
 * - an object block whose checksum fails as read is decrypted in place in the buffer cache, if that makes its
 *   checksum good: the unit is its block number;
 * - file data is read through apfs_read_folio_encrypted(), each block decrypted as its extent says (crypto_id plus
 *   the block's offset in the extent; crypto_id 0 is stored in the clear);
 * - a dstream read whole (xattrs, compressed files' resource forks) is decrypted the same way.
 * The container's own objects (its omap, space manager) are never encrypted, so their checksums pass as read.
 */
#include <linux/buffer_head.h>
#include <linux/highmem.h>
#include <linux/mm.h>
#include <linux/pagemap.h>
#include <linux/slab.h>
#include "apfs.h"
#include "unlock.h"

/* A keybag at PR, decrypted with UUID unless it is stored in the clear; *OUT is kvmalloc'ed. */
static int apfs_read_keybag(struct super_block *sb, const struct apfs_prange *pr, const u8 *uuid, u32 type,
			    u8 **out, size_t *len)
{
	u64 start = le64_to_cpu(pr->pr_start_paddr), count = le64_to_cpu(pr->pr_block_count), i;
	size_t bs = sb->s_blocksize;
	struct apfs_xts *x;
	u8 *buf;

	if (!start || !count || count > 16)
		return -EFSCORRUPTED;
	buf = kvmalloc(count * bs, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	for (i = 0; i < count; i++) {
		struct buffer_head *bh = apfs_sb_bread(sb, start + i);

		if (!bh) {
			kvfree(buf);
			return -EIO;
		}
		memcpy(buf + i * bs, bh->b_data, bs);
		brelse(bh);
	}
	if (le32_to_cpup((__le32 *)(buf + 0x18)) != type) {
		x = kmalloc(sizeof(*x), GFP_KERNEL);
		if (!x || apfs_xts_setkey(x, uuid, uuid)) {
			kfree(x);
			kvfree(buf);
			return -ENOMEM;
		}
		apfs_xts_decrypt(x, start * (bs >> 9), buf, count * bs);
		kfree_sensitive(x);
	}
	*out = buf;
	*len = count * bs;
	return 0;
}

int apfs_unlock_volume(struct super_block *sb)
{
	struct apfs_sb_info *sbi = APFS_SB(sb);
	struct apfs_nx_superblock *nx = APFS_NXI(sb)->nx_raw;
	struct apfs_superblock *vsb = sbi->s_vsb_raw;
	const u8 *vuuid = (const u8 *)vsb->apfs_vol_uuid;
	u8 *keys = NULL, *recs = NULL, *pw = NULL, vek[32];
	size_t klen, rlen = 0, pwlen;
	const u8 *e, *vb;
	u16 l, vl;
	int err;

	if (sbi->s_xts)
		return 0;
	if (!(le64_to_cpu(vsb->apfs_fs_flags) & APFS_FS_ONEKEY)) {
		apfs_warn(sb, "volume is encrypted with per-file keys, which are not supported");
		return -EOPNOTSUPP;
	}
	if (!sb_rdonly(sb)) {
		apfs_warn(sb, "an encrypted volume can only be mounted read-only");
		return -EROFS;
	}
	if (!sbi->s_pass) {
		apfs_warn(sb, "volume is encrypted: mount it with its password");
		return -ENOKEY;
	}
	pwlen = strlen(sbi->s_pass) / 2;
	pw = kmalloc(pwlen + 1, GFP_KERNEL);
	err = -ENOMEM;
	if (!pw)
		goto out;
	err = -EINVAL;
	if (strlen(sbi->s_pass) % 2 || hex2bin(pw, sbi->s_pass, pwlen)) {
		apfs_warn(sb, "pass= takes the password in hex");
		goto out;
	}

	err = apfs_read_keybag(sb, &nx->nx_keylocker, (const u8 *)nx->nx_uuid, APFS_UNLOCK_KEYS_TYPE, &keys, &klen);
	if (err) {
		apfs_err(sb, "cannot read the container keybag");
		goto out;
	}
	e = apfs_keybag_find(keys, klen, APFS_UNLOCK_KEYS_TYPE, vuuid, APFS_KB_TAG_RECS, &l, NULL);
	vb = apfs_keybag_find(keys, klen, APFS_UNLOCK_KEYS_TYPE, vuuid, APFS_KB_TAG_VEK, &vl, NULL);
	err = -EFSCORRUPTED;
	if (!e || l != sizeof(struct apfs_prange) || !vb) {
		apfs_err(sb, "the container keybag has no key for this volume");
		goto out;
	}
	err = apfs_read_keybag(sb, (const struct apfs_prange *)e, vuuid, APFS_UNLOCK_RECS_TYPE, &recs, &rlen);
	if (err) {
		apfs_err(sb, "cannot read the volume keybag");
		goto out;
	}
	err = apfs_unlock_vek(vb, vl, recs, rlen, pw, pwlen, vek);
	if (err == -EKEYREJECTED) {
		const u8 *hint = apfs_keybag_find(recs, rlen, APFS_UNLOCK_RECS_TYPE, vuuid, APFS_KB_TAG_HINT, &l, NULL);

		if (hint)
			apfs_warn(sb, "wrong password for the encrypted volume (hint: %.*s)", (int)l, hint);
		else
			apfs_warn(sb, "wrong password for the encrypted volume");
		goto out;
	}
	if (err) {
		apfs_err(sb, "the volume's key blobs are malformed");
		goto out;
	}
	sbi->s_xts = kmalloc(sizeof(*sbi->s_xts), GFP_KERNEL);
	err = -ENOMEM;
	if (!sbi->s_xts)
		goto out;
	err = apfs_xts_setkey(sbi->s_xts, vek, vek + 16);
	if (err) {
		kfree_sensitive(sbi->s_xts);
		sbi->s_xts = NULL;
		goto out;
	}
	apfs_info(sb, "encrypted volume unlocked");
out:
	memzero_explicit(vek, sizeof(vek));
	kfree_sensitive(pw);
	kvfree(keys);
	if (recs)
		kvfree_sensitive(recs, rlen);
	kfree_sensitive(sbi->s_pass);
	sbi->s_pass = NULL;
	return err;
}

void apfs_decrypt_object(struct super_block *sb, struct buffer_head *bh)
{
	size_t bs = sb->s_blocksize;
	char *tmp;

	lock_buffer(bh);
	if (apfs_multiblock_verify_csum(bh->b_data, bs))
		goto out;
	tmp = kmalloc(bs, GFP_NOFS);
	if (!tmp)
		goto out;
	memcpy(tmp, bh->b_data, bs);
	apfs_xts_decrypt(APFS_SB(sb)->s_xts, (u64)bh->b_blocknr << (sb->s_blocksize_bits - 9), (u8 *)tmp, bs);
	/* not encrypted after all (damage): leave it as read, so the checksum check reports it */
	if (apfs_multiblock_verify_csum(tmp, bs))
		memcpy(bh->b_data, tmp, bs);
	kfree_sensitive(tmp);
out:
	unlock_buffer(bh);
}

void apfs_decrypt_block(struct super_block *sb, void *buf, u64 tweak)
{
	apfs_xts_decrypt(APFS_SB(sb)->s_xts, tweak << (sb->s_blocksize_bits - 9), buf, sb->s_blocksize);
}

int apfs_read_folio_encrypted(struct folio *folio)
{
	struct inode *inode = folio->mapping->host;
	struct super_block *sb = inode->i_sb;
	struct apfs_nxsb_info *nxi = APFS_NXI(sb);
	struct apfs_dstream_info *ds = &APFS_I(inode)->i_dstream;
	size_t bs = sb->s_blocksize, off;
	int err = 0;

	for (off = 0; off < folio_size(folio) && !err; off += bs) {
		u64 dsblock = (folio_pos(folio) + off) >> sb->s_blocksize_bits, bno = 0, tweak = 0;
		char *dst = kmap_local_folio(folio, off);

		if (dsblock < (ds->ds_size + bs - 1) >> sb->s_blocksize_bits) {
			down_read(&nxi->nx_big_sem);
			err = apfs_logic_to_phys_crypto(ds, dsblock, &bno, &tweak);
			up_read(&nxi->nx_big_sem);
		}
		if (!err && bno) {
			struct buffer_head *bh = apfs_sb_bread(sb, bno);

			if (bh) {
				memcpy(dst, bh->b_data, bs);
				brelse(bh);
				if (tweak)
					apfs_decrypt_block(sb, dst, tweak);
			} else {
				err = -EIO;
			}
		} else {
			memset(dst, 0, bs);
		}
		kunmap_local(dst);
	}
	if (!err)
		folio_mark_uptodate(folio);
	folio_unlock(folio);
	return err;
}

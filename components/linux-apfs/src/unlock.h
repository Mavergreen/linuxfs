/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Unlocking a software-encrypted APFS volume with its password, and decrypting what it stores (linuxfs's addition to
 * linux-apfs-rw; the algorithm follows apfs-fuse's KeyMgmt.cpp). No I/O here: the caller reads the keybags.
 *
 * The container keybag ('keys', at nx_keylocker) and a volume's keybag ('recs') are stored XTS-encrypted, both keys
 * the owner's UUID (the container's, the volume's). In the container keybag, the volume's tag-2 entry is its wrapped
 * volume key (VEK) and its tag-3 entry the volume keybag's location; in the volume keybag, each tag-3 entry is a key
 * encryption key (KEK) wrapped by a password, and the tag-4 entry the password hint. Unlocking: PBKDF2 of the
 * password unwraps a KEK (RFC 3394), the KEK unwraps the VEK, and the VEK's halves are the XTS-AES-128 keys.
 *
 * Built in the kernel against lib/crypto's AES and SHA-256; elsewhere (tests) against unlock-host.h's.
 */
#ifndef APFS_UNLOCK_H
#define APFS_UNLOCK_H

#ifdef __KERNEL__
#include <linux/types.h>
#include <linux/string.h>
#include <linux/errno.h>
#include <crypto/aes.h>
#include <crypto/sha2.h>
typedef struct crypto_aes_ctx apfs_aes_ctx;
typedef struct sha256_state apfs_sha256_ctx;
#define apfs_aes_setkey(c, k, len)	aes_expandkey((c), (k), (len))
#define apfs_aes_encrypt(c, out, in)	aes_encrypt((c), (out), (in))
#define apfs_aes_decrypt(c, out, in)	aes_decrypt((c), (out), (in))
#define apfs_sha256_init(c)		sha256_init(c)
#define apfs_sha256_update(c, d, n)	sha256_update((c), (d), (n))
#define apfs_sha256_final(c, out)	sha256_final((c), (out))
#define apfs_wipe(p, n)			memzero_explicit((p), (n))
#else
#include "unlock-host.h"
#endif

#define APFS_UNLOCK_KEYS_TYPE	0x6b657973	/* 'keys': the container keybag's object type */
#define APFS_UNLOCK_RECS_TYPE	0x72656373	/* 'recs': a volume keybag's */
#define APFS_KB_TAG_VEK		2
#define APFS_KB_TAG_RECS	3		/* container keybag: where the volume keybag is; volume keybag: a KEK */
#define APFS_KB_TAG_HINT	4

struct apfs_xts {
	apfs_aes_ctx data;
	apfs_aes_ctx tweak;
};

/* XTS-AES-128 with data key K1 and tweak key K2, 16 bytes each. */
int apfs_xts_setkey(struct apfs_xts *x, const u8 *k1, const u8 *k2);
/* Decrypts LEN bytes (a multiple of 16) of one data unit, numbered UNIT, in place. */
void apfs_xts_decrypt_unit(const struct apfs_xts *x, u64 unit, u8 *buf, size_t len);
/* Decrypts LEN bytes (a multiple of 512) in place: 512-byte units numbered from FIRST, as APFS stores them. */
void apfs_xts_decrypt(const struct apfs_xts *x, u64 first, u8 *buf, size_t len);

void apfs_hmac_sha256(const u8 *key, size_t keylen, const u8 *msg, size_t len, u8 out[32]);
void apfs_pbkdf2_sha256(const u8 *pw, size_t pwlen, const u8 *salt, size_t saltlen, u32 iterations,
			u8 *out, size_t outlen);
/* RFC 3394: unwraps IN (LEN + 8 bytes) into OUT (LEN bytes) with the KEKLEN-byte KEK; -EKEYREJECTED if the check fails. */
int apfs_aes_unwrap(const u8 *kek, unsigned int keklen, const u8 *in, size_t len, u8 *out);

/*
 * In a decrypted keybag object BAG (LEN bytes, object type TYPE), the entry for UUID with TAG: returns its data and
 * sets *KEYLEN, or NULL when there is none or the keybag is malformed. A NULL UUID matches any entry; then *POS
 * (start at 0) resumes the search after the previous match.
 */
const u8 *apfs_keybag_find(const u8 *bag, size_t len, u32 type, const u8 *uuid, u16 tag, u16 *keylen, size_t *pos);

/*
 * Unwraps the volume key: VEK_BLOB (the container keybag's tag-2 entry for the volume) with the first KEK in RECS
 * (the decrypted volume keybag, LEN bytes) that PW unlocks. Fills VEK (32 bytes: the XTS data and tweak keys).
 * Returns 0, -EKEYREJECTED when the password unlocks no KEK, or -EINVAL when a blob is malformed.
 */
int apfs_unlock_vek(const u8 *vek_blob, u16 vek_len, const u8 *recs, size_t len, const u8 *pw, size_t pwlen, u8 vek[32]);

#endif

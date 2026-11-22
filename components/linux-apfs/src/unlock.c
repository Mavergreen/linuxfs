// SPDX-License-Identifier: GPL-2.0-only
/*
 * Unlocking a software-encrypted APFS volume (see unlock.h). linuxfs's addition to linux-apfs-rw.
 */
#include "unlock.h"

int apfs_xts_setkey(struct apfs_xts *x, const u8 *k1, const u8 *k2)
{
	int err = apfs_aes_setkey(&x->data, k1, 16);

	return err ? err : apfs_aes_setkey(&x->tweak, k2, 16);
}

void apfs_xts_decrypt_unit(const struct apfs_xts *x, u64 unit, u8 *buf, size_t len)
{
	u8 t[16] = { 0 }, b[16];
	size_t off;
	int i;

	for (i = 0; i < 8; i++)
		t[i] = (u8)(unit >> (8 * i));
	apfs_aes_encrypt(&x->tweak, t, t);
	for (off = 0; off + 16 <= len; off += 16) {
		u8 carry;

		for (i = 0; i < 16; i++)
			b[i] = buf[off + i] ^ t[i];
		apfs_aes_decrypt(&x->data, b, b);
		for (i = 0; i < 16; i++)
			buf[off + i] = b[i] ^ t[i];
		/* the next block's tweak: times x in GF(2^128), little-endian */
		carry = t[15] >> 7;
		for (i = 15; i > 0; i--)
			t[i] = (u8)(t[i] << 1 | t[i - 1] >> 7);
		t[0] = (u8)(t[0] << 1) ^ (carry ? 0x87 : 0);
	}
	apfs_wipe(b, sizeof(b));
}

void apfs_xts_decrypt(const struct apfs_xts *x, u64 first, u8 *buf, size_t len)
{
	size_t off;

	for (off = 0; off + 512 <= len; off += 512)
		apfs_xts_decrypt_unit(x, first++, buf + off, 512);
}

/* HMAC-SHA256's keyed inner and outer states, so PBKDF2 hashes the key once, not once per iteration */
struct hmac_keyed {
	apfs_sha256_ctx inner, outer;
};

static void hmac_key(struct hmac_keyed *h, const u8 *key, size_t keylen)
{
	u8 k[64] = { 0 }, pad[64];
	int i;

	if (keylen > 64) {
		apfs_sha256_init(&h->inner);
		apfs_sha256_update(&h->inner, key, keylen);
		apfs_sha256_final(&h->inner, k);
	} else {
		memcpy(k, key, keylen);
	}
	for (i = 0; i < 64; i++)
		pad[i] = k[i] ^ 0x36;
	apfs_sha256_init(&h->inner);
	apfs_sha256_update(&h->inner, pad, 64);
	for (i = 0; i < 64; i++)
		pad[i] = k[i] ^ 0x5c;
	apfs_sha256_init(&h->outer);
	apfs_sha256_update(&h->outer, pad, 64);
	apfs_wipe(k, sizeof(k));
	apfs_wipe(pad, sizeof(pad));
}

static void hmac_run(const struct hmac_keyed *h, const u8 *m1, size_t l1, const u8 *m2, size_t l2, u8 out[32])
{
	apfs_sha256_ctx c = h->inner;

	apfs_sha256_update(&c, m1, l1);
	if (l2)
		apfs_sha256_update(&c, m2, l2);
	apfs_sha256_final(&c, out);
	c = h->outer;
	apfs_sha256_update(&c, out, 32);
	apfs_sha256_final(&c, out);
	apfs_wipe(&c, sizeof(c));
}

void apfs_hmac_sha256(const u8 *key, size_t keylen, const u8 *msg, size_t len, u8 out[32])
{
	struct hmac_keyed h;

	hmac_key(&h, key, keylen);
	hmac_run(&h, msg, len, NULL, 0, out);
	apfs_wipe(&h, sizeof(h));
}

void apfs_pbkdf2_sha256(const u8 *pw, size_t pwlen, const u8 *salt, size_t saltlen, u32 iterations,
			u8 *out, size_t outlen)
{
	struct hmac_keyed h;
	u8 u[32], t[32], be[4];
	u32 block = 1, i;
	size_t n, k;

	hmac_key(&h, pw, pwlen);
	while (outlen) {
		be[0] = (u8)(block >> 24); be[1] = (u8)(block >> 16); be[2] = (u8)(block >> 8); be[3] = (u8)block;
		hmac_run(&h, salt, saltlen, be, 4, u);
		memcpy(t, u, 32);
		for (i = 1; i < iterations; i++) {
			hmac_run(&h, u, 32, NULL, 0, u);
			for (k = 0; k < 32; k++)
				t[k] ^= u[k];
		}
		n = outlen < 32 ? outlen : 32;
		memcpy(out, t, n);
		out += n;
		outlen -= n;
		block++;
	}
	apfs_wipe(&h, sizeof(h));
	apfs_wipe(u, sizeof(u));
	apfs_wipe(t, sizeof(t));
}

int apfs_aes_unwrap(const u8 *kek, unsigned int keklen, const u8 *in, size_t len, u8 *out)
{
	apfs_aes_ctx c;
	u8 a[8], b[16];
	size_t blocks = len / 8, i;
	int j, k, err = 0;

	if (len % 8 || blocks < 2 || apfs_aes_setkey(&c, kek, keklen))
		return -EINVAL;
	memcpy(a, in, 8);
	memmove(out, in + 8, len);
	for (j = 5; j >= 0; j--) {
		for (i = blocks; i >= 1; i--) {
			u64 t = (u64)blocks * (u64)j + i;

			memcpy(b, a, 8);
			for (k = 0; k < 8; k++)
				b[7 - k] ^= (u8)(t >> (8 * k));
			memcpy(b + 8, out + 8 * (i - 1), 8);
			apfs_aes_decrypt(&c, b, b);
			memcpy(a, b, 8);
			memcpy(out + 8 * (i - 1), b + 8, 8);
		}
	}
	for (k = 0; k < 8; k++)
		if (a[k] != 0xa6)
			err = -EKEYREJECTED;
	if (err)
		apfs_wipe(out, len);
	apfs_wipe(b, sizeof(b));
	apfs_wipe(&c, sizeof(c));
	return err;
}

static u32 le32(const u8 *p)
{
	return p[0] | (u32)p[1] << 8 | (u32)p[2] << 16 | (u32)p[3] << 24;
}

static u16 le16(const u8 *p)
{
	return (u16)(p[0] | p[1] << 8);
}

const u8 *apfs_keybag_find(const u8 *bag, size_t len, u32 type, const u8 *uuid, u16 tag, u16 *keylen, size_t *pos)
{
	size_t nbytes, off, start = pos ? *pos : 0;
	unsigned int nkeys, k;

	/* the object header (0x20), then the locker: version, key count, byte count (from the locker), padding */
	if (len < 0x30 || le32(bag + 0x18) != type || le16(bag + 0x20) != 2)
		return NULL;
	nkeys = le16(bag + 0x22);
	nbytes = le32(bag + 0x24);
	if (nbytes < 0x10 || nbytes > len - 0x20)
		return NULL;
	for (k = 0, off = 0x30; k < nkeys; k++) {
		u16 kl;
		size_t step;

		if (off + 24 > 0x20 + nbytes)
			return NULL;
		kl = le16(bag + off + 18);
		if (off + 24 + kl > 0x20 + nbytes)
			return NULL;
		step = (24 + (size_t)kl + 15) & ~(size_t)15;
		if (off >= start && le16(bag + off + 16) == tag && (!uuid || memcmp(bag + off, uuid, 16) == 0)) {
			*keylen = kl;
			if (pos)
				*pos = off + step;
			return bag + off + 24;
		}
		off += step;
	}
	return NULL;
}

/* DER: the value of the element at P (before END) with TAG; sets *VLEN. NULL if P holds another or is malformed. */
static const u8 *der_take(const u8 **p, const u8 *end, u8 tag, size_t *vlen)
{
	const u8 *q = *p;
	size_t l;

	if (end - q < 2 || q[0] != tag)
		return NULL;
	l = q[1];
	q += 2;
	if (l & 0x80) {
		int nb = l & 0x7f;

		if (nb < 1 || nb > 2 || end - q < nb)
			return NULL;
		for (l = 0; nb--; )
			l = l << 8 | *q++;
	}
	if ((size_t)(end - q) < l)
		return NULL;
	*vlen = l;
	*p = q + l;
	return q;
}

static int der_uint(const u8 **p, const u8 *end, u8 tag, u64 *v)
{
	size_t l;
	const u8 *q = der_take(p, end, tag, &l);

	if (!q || l < 1 || l > 9 || (l == 9 && q[0]))
		return -1;
	for (*v = 0; l--; )
		*v = *v << 8 | *q++;
	return 0;
}

struct key_blob {
	const u8 *uuid;		/* [3].[1], 16 bytes */
	u32 flags;		/* [3].[2], its first four bytes */
	const u8 *wrapped;	/* [3].[3] */
	size_t wlen;
	u64 iterations;		/* [3].[4], KEKs only */
	const u8 *salt;		/* [3].[5], KEKs only, 16 bytes */
};

static int parse_blob(const u8 *der, size_t len, int kek, struct key_blob *k)
{
	const u8 *p = der, *end = der + len, *body, *bend, *in, *iend;
	size_t l;
	u64 ignored;

	body = der_take(&p, end, 0x30, &l);
	if (!body)
		return -EINVAL;
	bend = body + l;
	p = body;
	if (der_uint(&p, bend, 0x80, &ignored) || !der_take(&p, bend, 0x81, &l) || !der_take(&p, bend, 0x82, &l))
		return -EINVAL;
	in = der_take(&p, bend, 0xa3, &l);
	if (!in)
		return -EINVAL;
	iend = in + l;
	p = in;
	if (der_uint(&p, iend, 0x80, &ignored))
		return -EINVAL;
	k->uuid = der_take(&p, iend, 0x81, &l);
	if (!k->uuid || l != 16)
		return -EINVAL;
	in = der_take(&p, iend, 0x82, &l);
	if (!in || l < 4)
		return -EINVAL;
	k->flags = le32(in);
	k->wrapped = der_take(&p, iend, 0x83, &k->wlen);
	if (!k->wrapped)
		return -EINVAL;
	if (kek) {
		if (der_uint(&p, iend, 0x84, &k->iterations) || k->iterations == 0 || k->iterations > 0xffffffffULL)
			return -EINVAL;
		k->salt = der_take(&p, iend, 0x85, &l);
		if (!k->salt || l != 16)
			return -EINVAL;
	}
	return 0;
}

/* Flag 2 in a blob's info: AES-128 (a volume converted from FileVault/CoreStorage) */
#define KEY_FLAG_AES128	2

int apfs_unlock_vek(const u8 *vek_blob, u16 vek_len, const u8 *recs, size_t len, const u8 *pw, size_t pwlen, u8 vek[32])
{
	struct key_blob v, kb;
	u8 dk[32], kek[32];
	unsigned int keklen = 0;
	size_t pos = 0;
	u16 kl;
	const u8 *e;
	int err = -EKEYREJECTED;

	if (parse_blob(vek_blob, vek_len, 0, &v))
		return -EINVAL;
	while ((e = apfs_keybag_find(recs, len, APFS_UNLOCK_RECS_TYPE, NULL, APFS_KB_TAG_RECS, &kl, &pos))) {
		if (parse_blob(e, kl, 1, &kb))
			continue;
		keklen = kb.flags & KEY_FLAG_AES128 ? 16 : 32;
		if (kb.wlen < keklen + 8)
			continue;
		apfs_pbkdf2_sha256(pw, pwlen, kb.salt, 16, (u32)kb.iterations, dk, sizeof(dk));
		if (apfs_aes_unwrap(dk, keklen, kb.wrapped, keklen, kek) == 0) {
			err = 0;
			break;
		}
	}
	apfs_wipe(dk, sizeof(dk));
	if (err)
		return err;

	if (v.flags & KEY_FLAG_AES128) {
		apfs_sha256_ctx s;
		u8 h[32];

		if (v.wlen < 24) {
			err = -EINVAL;
		} else if ((err = apfs_aes_unwrap(kek, keklen, v.wrapped, 16, vek)) == 0) {
			apfs_sha256_init(&s);
			apfs_sha256_update(&s, vek, 16);
			apfs_sha256_update(&s, v.uuid, 16);
			apfs_sha256_final(&s, h);
			memcpy(vek + 16, h, 16);
			apfs_wipe(h, sizeof(h));
		}
	} else {
		err = v.wlen < 40 ? -EINVAL : apfs_aes_unwrap(kek, keklen, v.wrapped, 32, vek);
	}
	apfs_wipe(kek, sizeof(kek));
	/* the password unwrapped a KEK, so a VEK that will not unwrap is damage, not a wrong password */
	return err == -EKEYREJECTED ? -EINVAL : err;
}

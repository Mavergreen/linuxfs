/*
 * Tests components/linux-apfs/src/unlock.c on the host, over CommonCrypto: the published vectors for each primitive
 * (RFC 3394, RFC 4231, RFC 7914's PBKDF2-SHA256, IEEE 1619), and unlocking keybags built here as macOS builds them.
 */
#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonSymmetricKeywrap.h>
#include <stdio.h>
#include <stdlib.h>
#include "unlock.h"

/* SPI in libcommonCrypto (no public header on 10.9): one XTS data unit with an explicit tweak */
extern CCCryptorStatus CCCryptorEncryptDataBlock(CCCryptorRef, const void *iv, const void *in, size_t len, void *out);

static int n, bad;

static void ok(int cond, const char *what)
{
	n++;
	printf("%sok %d - %s\n", cond ? "" : "not ", n, what);
	if (!cond)
		bad = 1;
}

static size_t unhex(const char *h, u8 *out)
{
	size_t i = 0;
	unsigned int b;

	for (; h[0] && h[1]; h += 2) {
		while (*h == ' ')
			h++;
		if (sscanf(h, "%2x", &b) != 1)
			break;
		out[i++] = (u8)b;
	}
	return i;
}

static int same(const u8 *got, const char *hex)
{
	u8 want[512];
	size_t len = unhex(hex, want);

	return memcmp(got, want, len) == 0;
}

/* --- building DER key blobs and keybags as macOS lays them out --- */
static size_t tlv(u8 *p, u8 tag, const u8 *v, size_t len)
{
	size_t h = 2;

	p[0] = tag;
	if (len < 0x80) {
		p[1] = (u8)len;
	} else {
		p[1] = 0x82; p[2] = (u8)(len >> 8); p[3] = (u8)len; h = 4;
	}
	memmove(p + h, v, len);
	return h + len;
}

static size_t uint_tlv(u8 *p, u8 tag, u64 v)
{
	u8 b[9];
	int i = 8, k = 0;

	do {
		b[i--] = (u8)v;
		v >>= 8;
		k++;
	} while (v);
	if (b[i + 1] & 0x80) {
		b[i--] = 0;
		k++;
	}
	return tlv(p, tag, b + i + 1, k);
}

/* A KEK (ITER and SALT16 given) or a VEK (ITER 0) blob: SEQ { [0] [1] hmac [2] salt [3] { [0] [1] uuid [2] info [3] wrapped ... } } */
static size_t blob(u8 *out, const u8 *uuid, u32 flags, const u8 *wrapped, size_t wlen, u64 iter, const u8 *salt16)
{
	u8 inner[256], outer[512], info[0x16] = { 0 }, zero[32] = { 0 };
	size_t i = 0, o = 0;

	info[0] = (u8)flags; info[1] = (u8)(flags >> 8);
	i += uint_tlv(inner + i, 0x80, 0);
	i += tlv(inner + i, 0x81, uuid, 16);
	i += tlv(inner + i, 0x82, info, sizeof(info));
	i += tlv(inner + i, 0x83, wrapped, wlen);
	if (iter) {
		i += uint_tlv(inner + i, 0x84, iter);
		i += tlv(inner + i, 0x85, salt16, 16);
	}
	o += uint_tlv(outer + o, 0x80, 0);
	o += tlv(outer + o, 0x81, zero, 32);
	o += tlv(outer + o, 0x82, zero, 8);
	o += tlv(outer + o, 0xa3, inner, i);
	return tlv(out, 0x30, outer, o);
}

struct entry { const u8 *uuid; u16 tag; const u8 *data; u16 len; };

static size_t keybag(u8 *out, u32 type, const struct entry *e, int count)
{
	size_t p = 0x30;

	memset(out, 0, 4096);
	out[0x18] = (u8)type; out[0x19] = (u8)(type >> 8); out[0x1a] = (u8)(type >> 16); out[0x1b] = (u8)(type >> 24);
	out[0x20] = 2;
	out[0x22] = (u8)count;
	for (int k = 0; k < count; k++) {
		memcpy(out + p, e[k].uuid, 16);
		out[p + 16] = (u8)e[k].tag;
		out[p + 18] = (u8)e[k].len; out[p + 19] = (u8)(e[k].len >> 8);
		memcpy(out + p + 24, e[k].data, e[k].len);
		p += (24 + e[k].len + 15) & ~(size_t)15;
	}
	out[0x24] = (u8)(p - 0x20); out[0x25] = (u8)((p - 0x20) >> 8);
	return 4096;
}

static void wrap(const u8 *kek, size_t keklen, const u8 *key, size_t keylen, u8 *out)
{
	size_t outlen = keylen + 8;

	CCSymmetricKeyWrap(kCCWRAPAES, CCrfc3394_iv, CCrfc3394_ivLen, kek, keklen, key, keylen, out, &outlen);
}

static void dk(const char *pw, const u8 *salt, u32 iter, u8 *out)
{
	CCKeyDerivationPBKDF(kCCPBKDF2, pw, strlen(pw), salt, 16, kCCPRFHmacAlgSHA256, iter, out, 32);
}

/* --- the fixture macOS made (tests/fixtures/apfs/enc.img), unlocked and decrypted here --- */
static FILE *img;

static u32 le32(const u8 *p) { return p[0] | (u32)p[1] << 8 | (u32)p[2] << 16 | (u32)p[3] << 24; }
static u16 le16(const u8 *p) { return (u16)(p[0] | p[1] << 8); }

static u64 g64(const u8 *p) { return (u64)le32(p) | (u64)le32(p + 4) << 32; }

static int rd(u64 b, u8 *buf)
{
	return fseeko(img, (off_t)(b * 4096), SEEK_SET) == 0 && fread(buf, 1, 4096, img) == 4096;
}

/* APFS's Fletcher-64 over the block after its checksum field */
static int csum_ok(const u8 *b)
{
	u64 s1 = 0, s2 = 0, c1, c2;

	for (int i = 8; i < 4096; i += 4) {
		s1 = (s1 + le32(b + i)) % 0xffffffffULL;
		s2 = (s2 + s1) % 0xffffffffULL;
	}
	c1 = 0xffffffffULL - (s1 + s2) % 0xffffffffULL;
	c2 = 0xffffffffULL - (s1 + c1) % 0xffffffffULL;
	return g64(b) == (c2 << 32 | c1);
}

/* An object map (at OMAP, physical): OID's newest physical address and flags */
static int omap_lookup(u64 omap, u64 oid, u64 *paddr, u32 *flags)
{
	u8 n[4096];
	u64 node;

	if (!rd(omap, n))
		return -1;
	node = g64(n + 0x30);
	for (int depth = 0; depth < 8; depth++) {
		unsigned int nflags, level, nkeys, toff, tlen, keys, vend;
		int pick = -1;

		if (!rd(node, n))
			return -1;
		nflags = le16(n + 0x20); level = le16(n + 0x22); nkeys = le32(n + 0x24);
		toff = le16(n + 0x28); tlen = le16(n + 0x2a);
		keys = 0x38 + toff + tlen;
		vend = nflags & 1 ? 4096 - 0x28 : 4096;
		for (unsigned int i = 0; i < nkeys; i++) {
			u64 koid = g64(n + keys + le16(n + 0x38 + toff + 4 * i));

			if (level ? koid <= oid : koid == oid)
				pick = (int)i;
		}
		if (pick < 0)
			return -1;
		{
			const u8 *v = n + vend - le16(n + 0x38 + toff + 4 * pick + 2);

			if (level) {
				node = g64(v);
				continue;
			}
			*flags = le32(v);
			*paddr = g64(v + 8);
			return 0;
		}
	}
	return -1;
}

/* A keybag at PR (start, count), decrypted with UUID unless stored in the clear */
static size_t keybag_at(const u8 *pr, const u8 *uuid, u32 type, u8 *out)
{
	u64 start = g64(pr), count = g64(pr + 8);
	struct apfs_xts x;

	if (!count || count > 4)
		return 0;
	for (u64 i = 0; i < count; i++)
		if (!rd(start + i, out + 4096 * i))
			return 0;
	if (le32(out + 0x18) != type) {
		apfs_xts_setkey(&x, uuid, uuid);
		apfs_xts_decrypt(&x, start * 8, out, 4096 * count);
	}
	return 4096 * count;
}

static void fixture(const char *path)
{
	static u8 nx[4096], vsb[4096], keys[16384], recs[16384], node[4096];
	u8 vek[32], secret_uuid[16];
	u64 paddr = 0, sroot = 0, somap = 0;
	u32 flags = 0;
	size_t klen, rlen = 0;
	const u8 *e, *vb = NULL;
	u16 l, vl = 0;
	int found = 0, plain = 0;

	img = fopen(path, "rb");
	ok(img && rd(0, nx) && memcmp(nx + 0x20, "NXSB", 4) == 0, "the fixture is an APFS container");
	if (!img)
		return;
	for (int v = 0; v < 2; v++) {
		u64 fs = g64(nx + 0xb8 + 8 * v);

		if (!fs || omap_lookup(g64(nx + 0xa0), fs, &paddr, &flags) || !rd(paddr, vsb))
			continue;
		if (strcmp((char *)vsb + 0x2c0, "Secret") == 0) {
			u64 ff = g64(vsb + 0x108);

			found = 1;
			memcpy(secret_uuid, vsb + 0xf0, 16);
			somap = g64(vsb + 0x80);
			sroot = g64(vsb + 0x88);
			ok(!(ff & 1) && (ff & 8), "volume Secret is software-encrypted with one key (APFS_FS_ONEKEY), as crypt.c requires");
		} else if (strcmp((char *)vsb + 0x2c0, "Plain") == 0) {
			plain = (g64(vsb + 0x108) & 1) != 0;
		}
	}
	ok(found, "volume Secret is in the container");
	ok(plain, "volume Plain is marked unencrypted");
	if (!found)
		return;
	klen = keybag_at(nx + 0x510, nx + 0x48, APFS_UNLOCK_KEYS_TYPE, keys);
	e = klen ? apfs_keybag_find(keys, klen, APFS_UNLOCK_KEYS_TYPE, secret_uuid, APFS_KB_TAG_RECS, &l, NULL) : NULL;
	if (e && l == 16)
		rlen = keybag_at(e, secret_uuid, APFS_UNLOCK_RECS_TYPE, recs);
	if (klen)
		vb = apfs_keybag_find(keys, klen, APFS_UNLOCK_KEYS_TYPE, secret_uuid, APFS_KB_TAG_VEK, &vl, NULL);
	ok(vb && rlen, "the container keybag decrypts, and names Secret's volume key and keybag");
	if (!vb || !rlen)
		return;
	e = apfs_keybag_find(recs, rlen, APFS_UNLOCK_RECS_TYPE, secret_uuid, APFS_KB_TAG_HINT, &l, NULL);
	ok(e && l == 4 && memcmp(e, "test", 4) == 0, "Secret's keybag gives its hint, \"test\"");
	ok(apfs_unlock_vek(vb, vl, recs, rlen, (const u8 *)"wrong", 5, vek) == -EKEYREJECTED, "a wrong password is rejected");
	ok(apfs_unlock_vek(vb, vl, recs, rlen, (const u8 *)"linuxfs-test", 12, vek) == 0, "its password unlocks the volume key");
	ok(omap_lookup(somap, sroot, &paddr, &flags) == 0 && (flags & 4) && rd(paddr, node) && !csum_ok(node),
	   "the root of Secret's file tree is stored encrypted (APFS_OMAP_VAL_ENCRYPTED)");
	{
		struct apfs_xts x;

		apfs_xts_setkey(&x, vek, vek + 16);
		apfs_xts_decrypt(&x, paddr * 8, node, 4096);
		ok(csum_ok(node) && (le32(node + 0x18) & 0xffff) == 2, "and decrypts, with the volume key at its block, to a b-tree root whose checksum holds");
	}
	fclose(img);
}

int main(int argc, char **argv)
{
	u8 a[512], b[512], c[512], kek[32], key[64];

	/* RFC 3394 4.1 and 4.6 */
	unhex("000102030405060708090A0B0C0D0E0F", kek);
	unhex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5", a);
	ok(apfs_aes_unwrap(kek, 16, a, 16, b) == 0 && same(b, "00112233445566778899AABBCCDDEEFF"),
	   "RFC 3394 4.1: 128-bit key data, 128-bit KEK");
	unhex("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F", kek);
	unhex("28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326CBC7F0E71A99F43BFB988B9B7A02DD21", a);
	ok(apfs_aes_unwrap(kek, 32, a, 32, b) == 0 &&
	   same(b, "00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F"),
	   "RFC 3394 4.6: 256-bit key data, 256-bit KEK");
	kek[0] ^= 1;
	ok(apfs_aes_unwrap(kek, 32, a, 32, b) == -EKEYREJECTED, "unwrapping with the wrong KEK is rejected");

	/* RFC 4231 test case 2 */
	apfs_hmac_sha256((const u8 *)"Jefe", 4, (const u8 *)"what do ya want for nothing?", 28, a);
	ok(same(a, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"), "HMAC-SHA256: RFC 4231 case 2");
	memset(b, 0xaa, 131);
	apfs_hmac_sha256(b, 131, (const u8 *)"Test Using Larger Than Block-Size Key - Hash Key First", 54, a);
	ok(same(a, "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
	   "HMAC-SHA256: RFC 4231 case 6 (a key longer than a block)");

	/* PBKDF2-HMAC-SHA256 ("password", "salt") */
	apfs_pbkdf2_sha256((const u8 *)"password", 8, (const u8 *)"salt", 4, 1, a, 32);
	ok(same(a, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"), "PBKDF2-SHA256, 1 iteration");
	apfs_pbkdf2_sha256((const u8 *)"password", 8, (const u8 *)"salt", 4, 4096, a, 32);
	ok(same(a, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"), "PBKDF2-SHA256, 4096 iterations");
	apfs_pbkdf2_sha256((const u8 *)"passwd", 6, (const u8 *)"salt", 4, 1, a, 64);
	ok(same(a, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
		   "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"),
	   "PBKDF2-SHA256, 64 bytes (two blocks): RFC 7914");

	/* XTS-AES-128: IEEE 1619 vectors 1-3 */
	{
		struct apfs_xts x;

		memset(key, 0, 32);
		apfs_xts_setkey(&x, key, key + 16);
		unhex("917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e", a);
		apfs_xts_decrypt_unit(&x, 0, a, 32);
		memset(b, 0, 32);
		ok(memcmp(a, b, 32) == 0, "XTS-AES-128: IEEE 1619 vector 1");
		memset(key, 0x11, 16); memset(key + 16, 0x22, 16);
		apfs_xts_setkey(&x, key, key + 16);
		unhex("c454185e6a16936e39334038acef838bfb186fff7480adc4289382ecd6d394f0", a);
		apfs_xts_decrypt_unit(&x, 0x3333333333ULL, a, 32);
		memset(b, 0x44, 32);
		ok(memcmp(a, b, 32) == 0, "XTS-AES-128: IEEE 1619 vector 2");
		unhex("fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0", key);
		apfs_xts_setkey(&x, key, key + 16);
		unhex("af85336b597afc1a900b2eb21ec949d292df4c047e0b21532186a5971a227a89", a);
		apfs_xts_decrypt_unit(&x, 0x3333333333ULL, a, 32);
		ok(memcmp(a, b, 32) == 0, "XTS-AES-128: IEEE 1619 vector 3");

		/* whole 512-byte units, numbered on from the first, against CommonCrypto's XTS */
		{
			static u8 plain[2048], enc[2048];
			CCCryptorRef r;
			u8 tw[16] = { 0 };
			int good = 1;

			for (int i = 0; i < 2048; i++)
				plain[i] = (u8)(i * 7 + 3);
			unhex("2718281828459045235360287471352631415926535897932384626433832795", key);
			if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeXTS, kCCAlgorithmAES128, ccNoPadding, NULL, key, 16,
						    key + 16, 16, 0, 0, &r) != kCCSuccess)
				good = 0;
			for (u64 u = 0; good && u < 4; u++) {
				u64 unit = 0x1234567ULL + u;

				for (int i = 0; i < 8; i++)
					tw[i] = (u8)(unit >> (8 * i));
				if (CCCryptorEncryptDataBlock(r, tw, plain + 512 * u, 512, enc + 512 * u) != kCCSuccess)
					good = 0;
			}
			apfs_xts_setkey(&x, key, key + 16);
			apfs_xts_decrypt(&x, 0x1234567ULL, enc, 2048);
			ok(good && memcmp(enc, plain, 2048) == 0, "XTS: four 512-byte units decrypt as CommonCrypto encrypted them");
		}
	}

	/* keybags */
	{
		static u8 recs[4096], keys[4096], vb[512], kb1[512], kb2[512];
		u8 vuuid[16], cuuid[16], useruuid[16], recoveryuuid[16], salt1[16], salt2[16], vek[32], kek1[32], d[32], got[32];
		u16 len;
		size_t pos = 0, vlen, k1, k2;
		const u8 *e;

		memset(vuuid, 0x56, 16); memset(cuuid, 0xc0, 16); memset(useruuid, 0xee, 16); memset(recoveryuuid, 0xec, 16);
		memset(salt1, 0x51, 16); memset(salt2, 0x52, 16);
		for (int i = 0; i < 32; i++) {
			vek[i] = (u8)(0xa0 + i);
			kek1[i] = (u8)(0x10 + i);
		}
		/* the volume key wrapped by the KEK; the KEK wrapped by each of two passwords */
		wrap(kek1, 32, vek, 32, a);
		vlen = blob(vb, vuuid, 0, a, 40, 0, NULL);
		dk("recovery-key", salt1, 1000, d);
		wrap(d, 32, kek1, 32, a);
		k1 = blob(kb1, recoveryuuid, 0, a, 40, 1000, salt1);
		dk("linuxfs-test", salt2, 20000, d);
		wrap(d, 32, kek1, 32, a);
		k2 = blob(kb2, useruuid, 0, a, 40, 20000, salt2);
		{
			struct entry r[] = { { recoveryuuid, 3, kb1, (u16)k1 }, { useruuid, 3, kb2, (u16)k2 },
					     { vuuid, 4, (const u8 *)"test", 4 } };
			keybag(recs, APFS_UNLOCK_RECS_TYPE, r, 3);
		}
		{
			u8 prange[16] = { 0x40, 0, 0, 0, 0, 0, 0, 0, 1 };
			struct entry k[] = { { vuuid, 2, vb, (u16)vlen }, { vuuid, 3, prange, 16 } };
			keybag(keys, APFS_UNLOCK_KEYS_TYPE, k, 2);
		}

		e = apfs_keybag_find(keys, 4096, APFS_UNLOCK_KEYS_TYPE, vuuid, 3, &len, NULL);
		ok(e && len == 16 && e[0] == 0x40 && e[8] == 1, "the container keybag gives the volume keybag's location");
		ok(apfs_keybag_find(keys, 4096, APFS_UNLOCK_KEYS_TYPE, cuuid, 2, &len, NULL) == NULL,
		   "and nothing for a volume it has no entry for");
		ok(apfs_keybag_find(keys, 4096, APFS_UNLOCK_RECS_TYPE, vuuid, 3, &len, NULL) == NULL,
		   "a keybag of the wrong type is refused");
		e = apfs_keybag_find(recs, 4096, APFS_UNLOCK_RECS_TYPE, vuuid, 4, &len, NULL);
		ok(e && len == 4 && memcmp(e, "test", 4) == 0, "the volume keybag gives the password hint");
		e = apfs_keybag_find(recs, 4096, APFS_UNLOCK_RECS_TYPE, NULL, 3, &len, &pos);
		e = e ? apfs_keybag_find(recs, 4096, APFS_UNLOCK_RECS_TYPE, NULL, 3, &len, &pos) : NULL;
		ok(e && len == k2 && apfs_keybag_find(recs, 4096, APFS_UNLOCK_RECS_TYPE, NULL, 3, &len, &pos) == NULL,
		   "with no UUID, the search walks every entry of the tag");
		memcpy(c, keys, 512);
		c[0x24] = 0xff; c[0x25] = 0x0f;		/* nbytes past the buffer */
		ok(apfs_keybag_find(c, 512, APFS_UNLOCK_KEYS_TYPE, vuuid, 2, &len, NULL) == NULL, "a keybag longer than its buffer is refused");
		memcpy(c, keys, 512);
		c[0x30 + 18] = 0xf0;			/* an entry running past the keybag */
		ok(apfs_keybag_find(c, 512, APFS_UNLOCK_KEYS_TYPE, vuuid, 3, &len, NULL) == NULL, "an entry longer than the keybag is refused");
		memcpy(c, keys, 512);
		c[0x20] = 1;
		ok(apfs_keybag_find(c, 512, APFS_UNLOCK_KEYS_TYPE, vuuid, 2, &len, NULL) == NULL, "a keybag not version 2 is refused");

		memset(got, 0, 32);
		ok(apfs_unlock_vek(vb, (u16)vlen, recs, 4096, (const u8 *)"linuxfs-test", 12, got) == 0 && memcmp(got, vek, 32) == 0,
		   "the password unlocks the volume key (through the second KEK)");
		ok(apfs_unlock_vek(vb, (u16)vlen, recs, 4096, (const u8 *)"recovery-key", 12, got) == 0 && memcmp(got, vek, 32) == 0,
		   "so does the other KEK's password");
		ok(apfs_unlock_vek(vb, (u16)vlen, recs, 4096, (const u8 *)"wrong", 5, got) == -EKEYREJECTED,
		   "a wrong password is rejected");
		memcpy(c, vb, vlen);
		c[1] = 0x7f;				/* the outer sequence claims more than there is */
		ok(apfs_unlock_vek(c, (u16)vlen, recs, 4096, (const u8 *)"linuxfs-test", 12, got) == -EINVAL,
		   "a malformed volume key blob is refused");

		/* a volume converted from FileVault/CoreStorage: an AES-128 KEK and a 16-byte volume key whose second
		 * half is SHA-256(key || the blob's UUID)[0:16] */
		{
			u8 v16[16], kek16[16], full[32], h[32];
			apfs_sha256_ctx s;
			struct entry r[1];

			memcpy(v16, vek, 16);
			memcpy(kek16, kek1, 16);
			wrap(kek16, 16, v16, 16, a);
			vlen = blob(vb, vuuid, 2, a, 24, 0, NULL);
			dk("linuxfs-test", salt2, 20000, d);
			wrap(d, 16, kek16, 16, a);	/* AES-128: the first half of the derived key */
			k2 = blob(kb2, useruuid, 2, a, 24, 20000, salt2);
			r[0] = (struct entry){ useruuid, 3, kb2, (u16)k2 };
			keybag(recs, APFS_UNLOCK_RECS_TYPE, r, 1);
			apfs_sha256_init(&s);
			apfs_sha256_update(&s, v16, 16);
			apfs_sha256_update(&s, vuuid, 16);
			apfs_sha256_final(&s, h);
			memcpy(full, v16, 16);
			memcpy(full + 16, h, 16);
			ok(apfs_unlock_vek(vb, (u16)vlen, recs, 4096, (const u8 *)"linuxfs-test", 12, got) == 0 &&
			   memcmp(got, full, 32) == 0, "a CoreStorage-converted volume's key is completed from its hash");
		}
	}

	if (argc > 1)
		fixture(argv[1]);
	printf("1..%d\n", n);
	return bad;
}

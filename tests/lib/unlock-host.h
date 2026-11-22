/* The primitives unlock.c needs, from CommonCrypto (macOS 10.9 has it), for tests/apfs-unlock-test. */
#ifndef APFS_UNLOCK_HOST_H
#define APFS_UNLOCK_HOST_H
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#ifndef EKEYREJECTED
#define EKEYREJECTED 129
#endif
typedef struct { CCCryptorRef enc, dec; } apfs_aes_ctx;
typedef CC_SHA256_CTX apfs_sha256_ctx;
static inline int apfs_aes_setkey(apfs_aes_ctx *c, const u8 *k, unsigned int len)
{
	if (CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode, k, len, NULL, &c->enc) ||
	    CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode, k, len, NULL, &c->dec))
		return -EINVAL;
	return 0;
}
static inline void apfs_aes_crypt(CCCryptorRef r, u8 *out, const u8 *in)
{
	size_t n;
	CCCryptorUpdate(r, in, 16, out, 16, &n);
}
#define apfs_aes_encrypt(c, out, in)	apfs_aes_crypt((c)->enc, (out), (in))
#define apfs_aes_decrypt(c, out, in)	apfs_aes_crypt((c)->dec, (out), (in))
#define apfs_sha256_init(c)		CC_SHA256_Init(c)
#define apfs_sha256_update(c, d, n)	CC_SHA256_Update((c), (d), (CC_LONG)(n))
#define apfs_sha256_final(c, out)	CC_SHA256_Final((out), (c))
#define apfs_wipe(p, n)			memset((p), 0, (n))
#endif

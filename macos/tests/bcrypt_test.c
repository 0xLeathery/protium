/*
 * Uses BCrypt's asymmetric keys, which Wine implements with GnuTLS: an RSA key pair signs a hash
 * and verifies the signature, and two ECDH P-256 key pairs agree on a secret.
 *
 *   bcrypt_test.exe
 *
 * Prints one line, e.g.
 *   bcrypt: rsa sign 0 verify 0, ecdh agree 0 0 same 1
 * (NTSTATUS values) and exits 0 when everything succeeded and both sides derived the same secret.
 * Without GnuTLS, key generation fails with STATUS_NOT_IMPLEMENTED (c0000002).
 *
 * Built for x86_64 or i686 with the mingw compiler: -lbcrypt.
 */
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <string.h>

static NTSTATUS derive( BCRYPT_KEY_HANDLE priv, BCRYPT_KEY_HANDLE pub, UCHAR *out, ULONG *len )
{
    BCRYPT_SECRET_HANDLE secret;
    NTSTATUS status;

    if ((status = BCryptSecretAgreement( priv, pub, &secret, 0 ))) return status;
    status = BCryptDeriveKey( secret, L"TRUNCATE" /* BCRYPT_KDF_RAW_SECRET */, NULL, out, 64, len, 0 );
    BCryptDestroySecret( secret );
    return status;
}

int main( void )
{
    BCRYPT_ALG_HANDLE rsa, ecdh;
    BCRYPT_KEY_HANDLE key, a, b;
    BCRYPT_PKCS1_PADDING_INFO pad = { BCRYPT_SHA256_ALGORITHM };
    UCHAR hash[32], sig[512], sa[64], sb[64];
    ULONG siglen = 0, la = 0, lb = 0;
    NTSTATUS sign = -1, verify = -1, agree_a = -1, agree_b = -1;

    memset( hash, 0x5a, sizeof(hash) );
    if (!BCryptOpenAlgorithmProvider( &rsa, BCRYPT_RSA_ALGORITHM, NULL, 0 ) &&
        !BCryptGenerateKeyPair( rsa, &key, 2048, 0 ) && !BCryptFinalizeKeyPair( key, 0 ))
    {
        sign = BCryptSignHash( key, &pad, hash, sizeof(hash), sig, sizeof(sig), &siglen, BCRYPT_PAD_PKCS1 );
        if (!sign) verify = BCryptVerifySignature( key, &pad, hash, sizeof(hash), sig, siglen, BCRYPT_PAD_PKCS1 );
    }
    else sign = BCryptGenerateKeyPair( rsa, &key, 2048, 0 );

    if (!BCryptOpenAlgorithmProvider( &ecdh, BCRYPT_ECDH_P256_ALGORITHM, NULL, 0 ) &&
        !BCryptGenerateKeyPair( ecdh, &a, 256, 0 ) && !BCryptFinalizeKeyPair( a, 0 ) &&
        !BCryptGenerateKeyPair( ecdh, &b, 256, 0 ) && !BCryptFinalizeKeyPair( b, 0 ))
    {
        agree_a = derive( a, b, sa, &la );
        agree_b = derive( b, a, sb, &lb );
    }

    printf( "bcrypt: rsa sign %lx verify %lx, ecdh agree %lx %lx same %d\n", (unsigned long)sign,
            (unsigned long)verify, (unsigned long)agree_a, (unsigned long)agree_b,
            !agree_a && !agree_b && la == lb && la && !memcmp( sa, sb, la ) );
    return (!sign && !verify && !agree_a && !agree_b && la == lb && la && !memcmp( sa, sb, la )) ? 0 : 1;
}

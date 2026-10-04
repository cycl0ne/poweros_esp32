# crypto.library

crypto.library's functions: random bytes, hashes, HMAC, HKDF, AES and
modular exponentiation on the chip's own engines; key agreement and
signatures on X25519, Ed25519, P-256 and P-384, and RSA signatures.
A hash, an HMAC or a cipher under way is a context the caller keeps
(sdk.crypto); a call that can fail answers 0 or a CRYPTOERR_* code.

Generated from the source by `./zig build autodoc`.

## Index

- [FinishHash](#finishhash) - Ends a hash and writes its digest.
- [FinishHmac](#finishhmac) - Ends an HMAC and writes the MAC.
- [HkdfExpand](#hkdfexpand) - Expands a pseudorandom key into keying material of a given length (HKDF-Expand, RFC 5869).
- [HkdfExtract](#hkdfextract) - Extracts a pseudorandom key from input keying material and a salt (HKDF-Extract, RFC 5869).
- [InitCipher](#initcipher) - Sets up a context for AES in one mode, with a key and an IV.
- [InitHash](#inithash) - Sets up a context for a new hash of one algorithm.
- [InitHmac](#inithmac) - Sets up a context for a new HMAC with one hash algorithm and a key.
- [MakeKeyPair](#makekeypair) - Makes a key pair on a curve: a private key from the chip's random number generator, and the public key that goes with it.
- [ModExp](#modexp) - Raises a number to a power modulo another.
- [OpenGcm](#opengcm) - Checks a message's AES-GCM tag and, if it is right, decrypts it.
- [RandomBytes](#randombytes) - Fills a buffer with random bytes.
- [SealGcm](#sealgcm) - Encrypts a message with AES-GCM and writes its tag.
- [SharedSecret](#sharedsecret) - Works out the secret one's own private key shares with the owner of a public key: Diffie-Hellman on a curve.
- [Sign](#sign) - Signs a message with a private key: Ed25519.
- [UpdateCipher](#updatecipher) - Encrypts or decrypts data with the context's cipher.
- [UpdateHash](#updatehash) - Adds bytes to a hash under way.
- [UpdateHmac](#updatehmac) - Adds bytes to an HMAC under way.
- [VerifySignature](#verifysignature) - Checks a signature with a public key: RSA in both its encodings, ECDSA on P-256 and P-384, and Ed25519.

## FinishHash

Ends a hash and writes its digest.

**SYNOPSIS**

```zig
fn FinishHash(cb: *CryptoBase, context: *HashContext, digest: *anyopaque) u32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `context`: set up by InitHash, with the bytes given by UpdateHash.
- `digest`: room for the algorithm's digest - `digestLength`, or
  DIGEST_MAX for any.

**RESULT**

The digest's length in bytes: 20 for SHA-1, 28, 32, 48 or 64 for the
others. 0 for a context InitHash did not set up, and nothing written.

**BEHAVIOR**

The hash is padded as FIPS 180-4 says and its last blocks run; the
digest is written most significant byte first, as it is printed and
sent. The context is wiped: to hash again it needs InitHash.

**CONTEXT**

- Waits: yes, for the SHA engine while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`InitHash`, `UpdateHash`, `FinishHmac`

**EXAMPLES**

```zig
var digest: [crypto.DIGEST_MAX]u8 = undefined;
const length = cb.FinishHash(&context, &digest);
for (digest[0..length]) |byte| _ = Printf(dl, "%02x", .{byte});
```

## FinishHmac

Ends an HMAC and writes the MAC.

**SYNOPSIS**

```zig
fn FinishHmac(cb: *CryptoBase, context: *HmacContext, mac: *anyopaque) u32
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `context`: set up by InitHmac, with the bytes given by UpdateHmac.
- `mac`: room for the hash's digest - `digestLength`, or DIGEST_MAX
  for any.

**RESULT**

The MAC's length in bytes, the hash's digest length. 0 for a context
InitHmac did not set up, and nothing written.

**BEHAVIOR**

The inner hash is finished, its digest goes through the outer hash,
and the outer digest is the MAC. The context is wiped: another MAC
with the same key needs InitHmac again.

**CONTEXT**

- Waits: yes, for the SHA engine while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A MAC received is compared with the one computed in constant time -
every byte, not up to the first that differs - or the time taken
tells an attacker how much of a forgery was right.

**BUGS**

None known.

**SEE ALSO**

`InitHmac`, `UpdateHmac`, `FinishHash`

**EXAMPLES**

```zig
var mac: [crypto.DIGEST_MAX]u8 = undefined;
const length = cb.FinishHmac(&context, &mac);
var differ: u8 = 0;
for (mac[0..length], received[0..length]) |a, b| differ |= a ^ b;
if (differ != 0) return error.Forged;
```

## HkdfExpand

Expands a pseudorandom key into keying material of a given length (HKDF-Expand, RFC 5869).

**SYNOPSIS**

```zig
fn HkdfExpand(cb: *CryptoBase, algorithm: u32, prk: *const Bytes, info: *const Bytes, output: *anyopaque, length: u32) i32
```

**SINCE**

1.1. LVO -72.

**INPUTS**

- `algorithm`: the hash, HASH_SHA1 to HASH_SHA512.
- `prk`: the pseudorandom key, from HkdfExtract or a protocol's own
  secret; at least the digest's length, as the RFC asks.
- `info`: what the material is for; any length, none included.
- `output`: room for `length` bytes; it may not overlap `prk` or
  `info`.
- `length`: at most 255 times the digest's length.

**RESULT**

CRYPTOERR_OK, with the material in `output`; CRYPTOERR_ALGORITHM for
a hash there is not; CRYPTOERR_LENGTH for a `length` past 255 digests
or a `prk` shorter than one. Nothing is written on a failure.

**BEHAVIOR**

T(1) = HMAC(prk, info | 1), T(n) = HMAC(prk, T(n-1) | info | n), and
the output is T(1) | T(2) | ... cut to `length`.

**CONTEXT**

- Waits: for the SHA engine, while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept: the last block's copy on the stack is wiped.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`HkdfExtract`, `InitHmac`

**EXAMPLES**

```zig
var key: [16]u8 = undefined;
_ = cb.HkdfExpand(crypto.HASH_SHA256, &crypto.Bytes.of(&prk), &crypto.Bytes.of(label), &key, key.len);
```

## HkdfExtract

Extracts a pseudorandom key from input keying material and a salt (HKDF-Extract, RFC 5869).

**SYNOPSIS**

```zig
fn HkdfExtract(cb: *CryptoBase, algorithm: u32, salt: *const Bytes, material: *const Bytes, prk: *anyopaque) i32
```

**SINCE**

1.1. LVO -68.

**INPUTS**

- `algorithm`: the hash, HASH_SHA1 to HASH_SHA512.
- `salt`: any length, none at all included.
- `material`: the input keying material - a shared secret, say.
- `prk`: room for the digest's length (`digestLength(algorithm)`).

**RESULT**

CRYPTOERR_OK, with the key in `prk`; CRYPTOERR_ALGORITHM for a hash
there is not, with nothing written.

**BEHAVIOR**

The key is HMAC(salt, material). A salt of no bytes is a salt of the
digest's length in zeroes, as the RFC has it - for HMAC the two are
the same key.

**CONTEXT**

- Waits: for the SHA engine, while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept; the HMAC context used is wiped by FinishHmac.

**NOTES**

TLS 1.3's key schedule is this and HkdfExpand, the latter with the
protocol's own labels in `info`.

**BUGS**

None known.

**SEE ALSO**

`HkdfExpand`, `InitHmac`

**EXAMPLES**

```zig
var prk: [32]u8 = undefined;
_ = cb.HkdfExtract(crypto.HASH_SHA256, &crypto.Bytes.of(&salt), &crypto.Bytes.of(&secret), &prk);
```

## InitCipher

Sets up a context for AES in one mode, with a key and an IV.

**SYNOPSIS**

```zig
fn InitCipher(cb: *CryptoBase, context: *CipherContext, mode: u32, key: *const anyopaque, key_length: u32, iv: ?*const anyopaque) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `context`: the caller's, made with `.{}` so that its `size` is
  right; whatever it held before is dropped.
- `mode`: CIPHER_AES_ECB, CIPHER_AES_CBC or CIPHER_AES_CTR, with
  CIPHERF_DECRYPT or-ed in to decrypt.
- `key`: `key_length` bytes.
- `key_length`: 16 (AES-128) or 32 (AES-256).
- `iv`: 16 bytes - CBC's IV, CTR's first counter block. Not read for
  ECB, which may pass null.

**RESULT**

CRYPTOERR_OK; CRYPTOERR_ALGORITHM for a mode or a flag there is not;
CRYPTOERR_KEY for another key length; CRYPTOERR_LENGTH for CBC or CTR
without an IV. On an error the context is left empty and UpdateCipher
refuses it. CRYPTOERR_CONTEXT for a context whose `size` is less than
`@sizeOf(CipherContext)`, which is not written to at all.

**BEHAVIOR**

The key and the IV are copied into the context, which from here on
is all the cipher is: UpdateCipher takes the data in any number of
calls. A CBC context goes one way only - it encrypts, or with
CIPHERF_DECRYPT it decrypts. CTR does both alike and ignores the flag.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The context holds a copy of the key: the caller
clears it when it is done, as it would the key.

**NOTES**

A CTR counter block must never be used twice with the same key, and
ECB shows equal plaintext blocks as equal ciphertext blocks; ECB is
here to build other modes on, not to encrypt data with.

**BUGS**

AES-192 is not there: the engine takes 128- and 256-bit keys.

**SEE ALSO**

`UpdateCipher`, `SealGcm`

**EXAMPLES**

```zig
var context: crypto.CipherContext = .{};
if (cb.InitCipher(&context, crypto.CIPHER_AES_CBC | crypto.CIPHERF_DECRYPT, &key, 32, &iv) != crypto.CRYPTOERR_OK) return;
defer context = .{};
_ = cb.UpdateCipher(&context, data.ptr, data.ptr, data.len);
```

## InitHash

Sets up a context for a new hash of one algorithm.

**SYNOPSIS**

```zig
fn InitHash(cb: *CryptoBase, context: *HashContext, algorithm: u32) i32
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `context`: the caller's, made with `.{}` so that its `size` is
  right; whatever it held before is dropped.
- `algorithm`: HASH_SHA1, HASH_SHA224, HASH_SHA256, HASH_SHA384 or
  HASH_SHA512.

**RESULT**

CRYPTOERR_OK, or CRYPTOERR_ALGORITHM for an algorithm there is not;
the context is then left empty, and UpdateHash and FinishHash do
nothing with it. CRYPTOERR_CONTEXT for a context whose `size` is
less than `@sizeOf(HashContext)`, which is not written to at all.

**BEHAVIOR**

The context holds the whole hash from here to FinishHash: the bytes
that do not yet make a block, the state between blocks and the length
so far. Nothing is taken from the library, so any number of hashes
may be under way at once, by any number of tasks, each in its own
context.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated; the context stays the caller's.

**NOTES**

SHA-1 is here for the formats that still name it; nothing new should
rest on it.

**BUGS**

None known.

**SEE ALSO**

`UpdateHash`, `FinishHash`, `InitHmac`

**EXAMPLES**

```zig
var context: crypto.HashContext = .{};
var digest: [crypto.DIGEST_MAX]u8 = undefined;
if (cb.InitHash(&context, crypto.HASH_SHA256) != crypto.CRYPTOERR_OK) return;
cb.UpdateHash(&context, text.ptr, text.len);
const length = cb.FinishHash(&context, &digest);
```

## InitHmac

Sets up a context for a new HMAC with one hash algorithm and a key.

**SYNOPSIS**

```zig
fn InitHmac(cb: *CryptoBase, context: *HmacContext, algorithm: u32, key: ?*const anyopaque, key_length: u32) i32
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `context`: the caller's, made with `.{}` so that its `size` is
  right; whatever it held before is dropped.
- `algorithm`: HASH_SHA1, HASH_SHA224, HASH_SHA256, HASH_SHA384 or
  HASH_SHA512.
- `key`: the key's bytes; may be null when `key_length` is 0.
- `key_length`: any length. A key longer than the hash's block is
  hashed first, as RFC 2104 says.

**RESULT**

CRYPTOERR_OK, or CRYPTOERR_ALGORITHM for an algorithm there is not;
the context is then left empty, and UpdateHmac and FinishHmac do
nothing with it. CRYPTOERR_CONTEXT for a context whose `size` is
less than `@sizeOf(HmacContext)`, which is not written to at all.

**BEHAVIOR**

RFC 2104's HMAC: the key, padded to a block, is exclusive-ored with
0x36 and hashed ahead of the message in the inner hash, and with 0x5C
ahead of the inner digest in the outer. Both key blocks go through
the engine here, so the context holds no key, only the two hashes'
states; the copies made on the way are wiped.

**CONTEXT**

- Waits: yes, for the SHA engine while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated; the key is only read.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`UpdateHmac`, `FinishHmac`, `InitHash`

**EXAMPLES**

```zig
var context: crypto.HmacContext = .{};
var mac: [crypto.DIGEST_MAX]u8 = undefined;
_ = cb.InitHmac(&context, crypto.HASH_SHA256, key.ptr, key.len);
cb.UpdateHmac(&context, message.ptr, message.len);
const length = cb.FinishHmac(&context, &mac);
```

## MakeKeyPair

Makes a key pair on a curve: a private key from the chip's random number generator, and the public key that goes with it.

**SYNOPSIS**

```zig
fn MakeKeyPair(cb: *CryptoBase, curve: u32, private_key: *anyopaque, public_key: *anyopaque, public_length: *u32) i32
```

**SINCE**

1.1. LVO -76.

**INPUTS**

- `curve`: CURVE_X25519, CURVE_P256, CURVE_P384 or CURVE_ED25519.
- `private_key`: room for `privateLength(curve)` bytes.
- `public_key`: room for `publicLength(curve)` bytes
  (CURVE_PUBLIC_MAX takes any).
- `public_length`: where the public key's length goes.

**RESULT**

CRYPTOERR_OK, with both keys written; CRYPTOERR_ALGORITHM for a curve
there is not, with nothing written.

**BEHAVIOR**

Each key is in the form its standard gives it (`sdk.crypto`'s
CURVE_*). X25519's private key is 32 random bytes, clamped when it is
used; a P-curve's is a random number from 1 to the order less one,
drawn again until it is one; Ed25519's is a random seed, from which
the signing key is derived by SHA-512 as RFC 8032 has it. The public
key is the private key times the curve's base point, worked out in the
same steps for every private key.

**CONTEXT**

- Waits: for the SHA engine (Ed25519 only), while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The private key is the caller's, to use and then to overwrite; the
library keeps no copy.

**NOTES**

A key for one handshake is made, used once with SharedSecret and
wiped: what TLS 1.3 calls an ephemeral key. A P-256 key pair takes
one scalar multiplication, X25519 one, Ed25519 one and a hash.

**BUGS**

The keys are as good as `RandomBytes`, which is only random while the
chip's generator has a noise source running.

**SEE ALSO**

`SharedSecret`, `Sign`, `RandomBytes`

**EXAMPLES**

```zig
var private_key: [32]u8 = undefined;
var public_key: [crypto.CURVE_PUBLIC_MAX]u8 = undefined;
var length: u32 = 0;
_ = cb.MakeKeyPair(crypto.CURVE_X25519, &private_key, &public_key, &length);
```

## ModExp

Raises a number to a power modulo another.

**SYNOPSIS**

```zig
fn ModExp(cb: *CryptoBase, result: *anyopaque, base_value: *const Number, exponent: *const Number, modulus: *const Number) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `result`: room for as many bytes as `modulus.length`.
- `base_value`: any number of up to NUMBER_MAX significant bytes; it
  need not be less than the modulus.
- `exponent`: no longer than the modulus, counted in 32-bit words:
  the engine's operands are all as long as the modulus.
- `modulus`: odd, at least 3, of up to NUMBER_MAX (512) significant
  bytes - 4096 bits.

**RESULT**

CRYPTOERR_OK, with `base_value ^ exponent mod modulus` in `result`,
most significant byte first and as long as the modulus as given,
leading zeroes included. CRYPTOERR_NUMBER for an even modulus or one
less than 3; CRYPTOERR_LENGTH for a number longer than it may be.
Nothing is written on an error.

**BEHAVIOR**

The numbers are big-endian byte strings, as RSA and Diffie-Hellman
send them (PKCS #1's I2OSP), and are only read. The work is done
in the engine on operands as long as the modulus, in 32-bit words;
the library works out the engine's two constants for the modulus and
first reduces a base that is not less than it. An exponent of 0
answers 1.

The engine runs in its constant-time mode: each exponent bit costs the
same, 0 or 1. It starts from the exponent's highest 1 bit, which gives
away only how long the exponent is - a public exponent of 17 bits
takes 17 steps, a private one is as long as its modulus in any case.

**CONTEXT**

- Waits: yes, for the RSA engine while another task has it; the
  engine is held for the whole call.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The numbers' copies in the library and the
exponent in the engine are cleared before the call returns.

**NOTES**

The engine's constants are worked out in software on every call: R^2
mod M a word at a time (a 2048-bit modulus, 128 steps of 64 words
each), and a base not below the modulus reduced bit by bit. A base
below it - a signature, a ciphertext - is taken as it is.

**BUGS**

A private-key operation is not blinded: the engine's constant time is
what stands against timing, and nothing stands against power analysis.

**SEE ALSO**

`RandomBytes`

**EXAMPLES**

```zig
// An RSA signature checked: signature ^ e mod n.
var decoded: [256]u8 = undefined;
const s: crypto.Number = .{ .bytes = &signature, .length = 256 };
const e: crypto.Number = .{ .bytes = &.{ 1, 0, 1 }, .length = 3 };
const n: crypto.Number = .{ .bytes = &modulus, .length = 256 };
if (cb.ModExp(&decoded, &s, &e, &n) != crypto.CRYPTOERR_OK) return error.Key;
```

## OpenGcm

Checks a message's AES-GCM tag and, if it is right, decrypts it.

**SYNOPSIS**

```zig
fn OpenGcm(cb: *CryptoBase, message: *const GcmMessage) i32
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `message`: the key and the nonce it was sealed with, the header
  (`aad`, may be none), the ciphertext (`input`, `length` bytes, may
  be none), where the plaintext goes (`output`, `length` bytes; may be
  `input` itself) and the 16-byte tag that came with it.

**RESULT**

CRYPTOERR_OK; CRYPTOERR_TAG when the tag does not match the key,
nonce, header and ciphertext; CRYPTOERR_KEY for another key length;
CRYPTOERR_LENGTH for a nonce of no bytes, or a null buffer with a
length that is not 0.

**BEHAVIOR**

The tag is worked out over the header and the ciphertext and compared
with the one given, every byte of it whatever the first difference.
Only a message whose tag matches is decrypted: on CRYPTOERR_TAG the
output has not been written, so nothing forged is ever there to be
used by mistake.

**CONTEXT**

- Waits: yes, for the AES engine while another task has it; the
  engine is held for the whole message.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated; the message stays the caller's.

**NOTES**

None.

**BUGS**

GHASH runs in software, as in SealGcm.

**SEE ALSO**

`SealGcm`

**EXAMPLES**

```zig
switch (cb.OpenGcm(&message)) {
    crypto.CRYPTOERR_OK => {},
    crypto.CRYPTOERR_TAG => return error.Forged,
    else => return error.Open,
}
```

## RandomBytes

Fills a buffer with random bytes.

**SYNOPSIS**

```zig
fn RandomBytes(cb: *CryptoBase, buffer: *anyopaque, length: u32) void
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `buffer`: room for `length` bytes.
- `length`: any.

**RESULT**

None.

**BEHAVIOR**

The bytes come straight from the chip's generator, which draws on the
noise of the SAR ADCs the kernel keeps sampling from boot to the end,
whether or not the radio runs (and on the radio's as well when it
does). They are fit for keys, nonces and IVs as they are, with no
generator of the library's own in between.

**CONTEXT**

- Waits: no.
- Interrupts: yes.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The generator refills between reads in a few cycles; the reads are
spaced so that no word is read twice. `C:test/Crypto RANDOM` puts
20000 of its bits through FIPS 140-2's monobit, poker and long-run
tests.

**BUGS**

A driver that takes the SAR ADCs over for readings must leave them
sampling, or the generator is left with timing noise alone.

**SEE ALSO**

`SealGcm`, `InitCipher`

**EXAMPLES**

```zig
var key: [32]u8 = undefined;
cb.RandomBytes(&key, key.len);
```

## SealGcm

Encrypts a message with AES-GCM and writes its tag.

**SYNOPSIS**

```zig
fn SealGcm(cb: *CryptoBase, message: *const GcmMessage) i32
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `message`: the key (16 or 32 bytes), the nonce (12 bytes is what
  GCM is made for; any length but 0 is taken), the header to
  authenticate (`aad`, may be none), the plaintext (`input`,
  `length` bytes, may be none), where the ciphertext goes (`output`,
  `length` bytes; may be `input` itself) and where the 16-byte tag
  goes.

**RESULT**

CRYPTOERR_OK; CRYPTOERR_KEY for another key length; CRYPTOERR_LENGTH
for a nonce of no bytes, or a null buffer with a length that is not
0. Nothing is written on an error.

**BEHAVIOR**

The ciphertext is as long as the plaintext; the tag authenticates
the header and the ciphertext together, so neither can be changed, cut
or moved without OpenGcm noticing. The whole message is one call:
GCM's tag is over all of it.

**CONTEXT**

- Waits: yes, for the AES engine while another task has it; the
  engine is held for the whole message.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated; the message stays the caller's.

**NOTES**

A nonce is never used twice with the same key: two messages under one
nonce give away the exclusive-or of their plaintexts and let the tags
be forged. A counter kept for the key, or 12 bytes from RandomBytes,
is how a nonce is made.

**BUGS**

GHASH runs in software, bit by bit, and is slower than the engine:
it, not AES, sets the pace of a long message.

**SEE ALSO**

`OpenGcm`, `InitCipher`, `RandomBytes`

**EXAMPLES**

```zig
var tag: [crypto.GCM_TAG]u8 = undefined;
const message: crypto.GcmMessage = .{
    .key = &key, .key_length = 16, .nonce = &nonce, .nonce_length = 12,
    .aad = &header, .aad_length = header.len,
    .input = record.ptr, .output = record.ptr, .length = record.len,
    .tag = &tag,
};
if (cb.SealGcm(&message) != crypto.CRYPTOERR_OK) return error.Seal;
```

## SharedSecret

Works out the secret one's own private key shares with the owner of a public key: Diffie-Hellman on a curve.

**SYNOPSIS**

```zig
fn SharedSecret(cb: *CryptoBase, curve: u32, private_key: *const anyopaque, peer: *const Bytes, secret: *anyopaque) i32
```

**SINCE**

1.1. LVO -80.

**INPUTS**

- `curve`: CURVE_X25519, CURVE_P256 or CURVE_P384.
- `private_key`: one's own, `privateLength(curve)` bytes, from
  MakeKeyPair.
- `peer`: the other side's public key, as it came - 32 bytes for
  X25519, an uncompressed point for a P-curve.
- `secret`: room for `secretLength(curve)` bytes.

**RESULT**

CRYPTOERR_OK, with the secret written; CRYPTOERR_ALGORITHM for a
curve with no key agreement (CURVE_ED25519) or none at all;
CRYPTOERR_KEY for a public key of the wrong length, a point not on
the curve, a private key out of range, or a result that is no secret
(X25519's all zeroes, a P-curve's point at infinity) - `secret` is
then zeroes.

**BEHAVIOR**

The secret is the private key times the peer's point: for X25519 its
u-coordinate (RFC 7748), for a P-curve its x-coordinate (SEC 1), each
as its standard writes it. A peer's point is checked to be on the
curve before anything is multiplied by it, which is what stops a key
from being drawn out of a reply to a point that is not.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The secret is the caller's: feed it to HkdfExtract, then overwrite it.

**NOTES**

The work takes the same steps whatever the private key.

**BUGS**

None known.

**SEE ALSO**

`MakeKeyPair`, `HkdfExtract`

**EXAMPLES**

```zig
var secret: [32]u8 = undefined;
if (cb.SharedSecret(crypto.CURVE_X25519, &private_key, &crypto.Bytes.of(server_share), &secret) != crypto.CRYPTOERR_OK) return error.Handshake;
```

## Sign

Signs a message with a private key: Ed25519.

**SYNOPSIS**

```zig
fn Sign(cb: *CryptoBase, algorithm: u32, private_key: *const anyopaque, message: *const Bytes, signature: *anyopaque) i32
```

**SINCE**

1.1. LVO -88.

**INPUTS**

- `algorithm`: SIG_ED25519.
- `private_key`: the 32-byte seed, from MakeKeyPair(CURVE_ED25519).
- `message`: the whole message, any length.
- `signature`: room for SIGNATURE_ED25519 (64) bytes.

**RESULT**

CRYPTOERR_OK, with the signature written; CRYPTOERR_ALGORITHM for any
other algorithm, with nothing written.

**BEHAVIOR**

RFC 8032, 5.1.6: the seed hashed with SHA-512 into the secret scalar
and a prefix, the nonce r from the prefix and the message - so the
same message signed twice gives the same signature, and no random
number can give the key away - and S = r + k a modulo the group
order. The multiplications take the same steps whatever the key.

**CONTEXT**

- Waits: for the SHA engine, while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The key stays the caller's; what was derived from it is wiped before
the call returns.

**NOTES**

The message is hashed twice, so it must be in memory whole.

**BUGS**

None known.

**SEE ALSO**

`VerifySignature`, `MakeKeyPair`

**EXAMPLES**

```zig
var signature: [crypto.SIGNATURE_ED25519]u8 = undefined;
_ = cb.Sign(crypto.SIG_ED25519, &seed, &crypto.Bytes.of(message), &signature);
```

## UpdateCipher

Encrypts or decrypts data with the context's cipher.

**SYNOPSIS**

```zig
fn UpdateCipher(cb: *CryptoBase, context: *CipherContext, input: ?*const anyopaque, output: ?*anyopaque, length: u32) i32
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `context`: set up by InitCipher.
- `input`: `length` bytes; may be null when `length` is 0.
- `output`: room for `length` bytes. It may be `input` itself, for
  the data in place; it may not overlap it any other way.
- `length`: ECB and CBC: a multiple of 16. CTR: any.

**RESULT**

CRYPTOERR_OK; CRYPTOERR_ALGORITHM for a context InitCipher did not set
up; CRYPTOERR_LENGTH for ECB or CBC data that is not whole blocks, or
a null buffer. Nothing is written on an error.

**BEHAVIOR**

The data continues from where the last call left off: a CBC chain
runs on from the last block, a CTR counter from the last counter
block, and a CTR call that ended inside a block starts the next with
the rest of that block's key stream. So a message may be given in any
number of pieces, and comes out as one call with all of it would.

**CONTEXT**

- Waits: yes, for the AES engine while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

CBC does not pad: a message that is not whole blocks is padded by the
caller, as its format says (PKCS #7, TLS).

**BUGS**

None known.

**SEE ALSO**

`InitCipher`, `SealGcm`, `OpenGcm`

**EXAMPLES**

```zig
if (cb.UpdateCipher(&context, packet.ptr, packet.ptr, packet.len) != crypto.CRYPTOERR_OK) return error.Cipher;
```

## UpdateHash

Adds bytes to a hash under way.

**SYNOPSIS**

```zig
fn UpdateHash(cb: *CryptoBase, context: *HashContext, data: ?*const anyopaque, length: u32) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `context`: set up by InitHash.
- `data`: the bytes; may be null when `length` is 0.
- `length`: how many.

**RESULT**

None.

**BEHAVIOR**

The digest depends only on the bytes, not on how they were divided
between calls: one call with all of them and a thousand with one byte
each come to the same. Whole blocks go to the chip's SHA engine as
they are made up; the rest waits in the context for the next call.
A context InitHash did not set up, or one FinishHash has ended, takes
nothing.

**CONTEXT**

- Waits: yes, for the SHA engine while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands; `data` is only read.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`InitHash`, `FinishHash`

**EXAMPLES**

```zig
while (true) {
    const got = dl.Read(file, &chunk, chunk.len);
    if (got <= 0) break;
    cb.UpdateHash(&context, &chunk, @intCast(got));
}
```

## UpdateHmac

Adds bytes to an HMAC under way.

**SYNOPSIS**

```zig
fn UpdateHmac(cb: *CryptoBase, context: *HmacContext, data: ?*const anyopaque, length: u32) void
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `context`: set up by InitHmac.
- `data`: the bytes; may be null when `length` is 0.
- `length`: how many.

**RESULT**

None.

**BEHAVIOR**

The bytes go into the inner hash, as UpdateHash would take them: how
they are divided between calls makes no difference to the MAC. A
context InitHmac did not set up takes nothing.

**CONTEXT**

- Waits: yes, for the SHA engine while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands; `data` is only read.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`InitHmac`, `FinishHmac`, `UpdateHash`

**EXAMPLES**

```zig
cb.UpdateHmac(&context, header.ptr, header.len);
cb.UpdateHmac(&context, body.ptr, body.len);
```

## VerifySignature

Checks a signature with a public key: RSA in both its encodings, ECDSA on P-256 and P-384, and Ed25519.

**SYNOPSIS**

```zig
fn VerifySignature(cb: *CryptoBase, algorithm: u32, key: *const PublicKey, digest: *const Bytes, signature: *const Bytes) i32
```

**SINCE**

1.1. LVO -84.

**INPUTS**

- `algorithm`: a SIG_* - SIG_RSA_PKCS1_SHA256/384/512,
  SIG_RSA_PSS_SHA256/384/512, SIG_ECDSA_P256, SIG_ECDSA_P384,
  SIG_ED25519.
- `key`: for RSA its `modulus` and `exponent`, for the curves its
  `point` (an uncompressed point, or Ed25519's 32 bytes).
- `digest`: the hash of what was signed, made by the caller - of the
  algorithm's hash for RSA, of any hash for ECDSA. For SIG_ED25519 it
  is the whole message, which Ed25519 hashes itself.
- `signature`: as it came - RSA's as long as its modulus, ECDSA's
  DER-encoded, Ed25519's 64 bytes.

**RESULT**

CRYPTOERR_OK when the signature is good. CRYPTOERR_SIGNATURE when it
is not, or is not a signature at all (the wrong length, broken DER, a
number out of range). CRYPTOERR_KEY for a key that is none - an even
or empty modulus, a point not on the curve. CRYPTOERR_LENGTH for an
RSA digest whose length is not its hash's. CRYPTOERR_ALGORITHM for an
algorithm there is not.

**BEHAVIOR**

RSA raises the signature to the exponent with ModExp, through the
jump table, and checks the encoding: PKCS #1 v1.5's by building the
one the digest must have and comparing every byte; PSS's by undoing
the mask with MGF1 and checking the hash over its salt, of any
length. ECDSA takes the DER strictly (positive, minimal, nothing
after it), holds r and s to 1 to n - 1, cuts a digest longer than the
curve to the curve's size, and compares the x of u1 G + u2 Q with r
modulo n. Ed25519 refuses an S not below the group order, and checks
S B = R + k A with k = SHA-512(R, A, message).

SHA-1 is offered by none of them: it no longer stands for anything
signed.

**CONTEXT**

- Waits: for the RSA or SHA engine, while another task has it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Everything here is public, so it is not made to take the same time
for every input: a bad signature fails as soon as it is seen to be
bad. An RSA-2048 check is one short exponentiation on the engine; an
ECDSA check two scalar multiplications in software.

**BUGS**

None known.

**SEE ALSO**

`Sign`, `ModExp`, `InitHash`

**EXAMPLES**

```zig
const key: crypto.PublicKey = .{ .point = crypto.Bytes.of(&server_point) };
const good = cb.VerifySignature(crypto.SIG_ECDSA_P256, &key, &crypto.Bytes.of(&digest), &crypto.Bytes.of(der)) == crypto.CRYPTOERR_OK;
```

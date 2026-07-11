# 03 — Crypto & the SVP Protocol

How `secure_video_player` keeps a video file encrypted on disk, yet plays it —
including seeking — without ever writing the decrypted bytes back to storage.

Covers the crypto scheme as actually implemented, the file encryptor, the SVP
wire protocol, and the two platform decrypt-on-read data paths (Android
`CipherDataSource`, iOS `CipherResourceLoaderDelegate`).

---

## Tier 1 — Explain it to a kid

Imagine you have a diary, but every page is written in a secret scramble. If a
thief steals the diary, they just see gibberish. They can't read it.

You have a magic decoder ring. When *you* want to read page 40, you don't have
to start from page 1. You look at the page number, spin the ring to that
number, and the page turns readable — just that page, just while you're looking
at it. The moment you look away, it's scrambled again. You never rewrite the
diary in plain words; you only ever *see* the plain words on the page in front
of you.

That's what this part of the app does:

- The video file on your phone is the scrambled diary.
- The "page number" is where in the video you are (the beginning, the middle,
  the part you jumped to).
- The decoder ring is the **key** plus a little starting number called the
  **nonce**.
- The video player asks for a small piece ("give me the part around minute 3"),
  the app unscrambles just that piece in memory, hands it to the screen, and
  throws it away.

Because you can unscramble any page directly from its page number, you can
**jump around** the video instantly. And the readable pages only ever exist in
your hands (memory) for a heartbeat — never back in the diary.

One honest warning for the kid: this lock stops a stranger who only grabs the
diary. It does **not** stop someone who is looking over your shoulder while you
read, or someone who has secretly copied your decoder ring.

---

## Tier 2 — Engineer's view

### 2.1 The crypto scheme: AES in CTR mode, hand-built from AES-ECB

The security-relevant cipher is **AES-CTR** (`AesCtrScheme`,
`lib/src/crypto_scheme.dart:83-97`). It is *not* implemented with a library CTR
mode; both platforms construct the CTR keystream themselves out of single-block
AES-ECB and then XOR it into the data. This is the whole reason random access
works.

Parameters (read from code — do not assume):

- **Key**: 16 bytes (AES-128) or 32 bytes (AES-256). Enforced on both platforms:
  `android/.../CipherAdapter.kt:99`, `ios/Classes/CipherAdapter.swift:109`.
- **Nonce**: exactly 8 bytes. `CipherAdapter.kt:102`, `CipherAdapter.swift:116`.
- **Block size**: 16 bytes (AES block). The 128-bit CTR input block is
  `nonce (8 bytes) || blockIndex (8 bytes, big-endian)`.
- **No header, no tag, no stored IV**: ciphertext length == plaintext length.
  `plaintextSize()` is the identity function (`CipherAdapter.kt:20`,
  `CipherAdapter.swift:15`). The key and nonce travel out-of-band through the
  Dart API, never inside the file.

The keystream / counter math (identical on both platforms):

```
firstBlock = filePosition / 16          // which AES block this read starts in
skip       = filePosition % 16          // byte offset inside that first block
blockCount = (skip + length + 15) / 16  // blocks the read spans
for b in 0..<blockCount:
    counterBlock[b] = nonce(8) || (firstBlock + b) as uint64 big-endian
keystream = AES-ECB-encrypt(key, all counterBlocks)   // one batched call
for i in 0..<length:
    out[i] = in[i] XOR keystream[skip + i]
```

- Android: `CipherAdapter.kt:106-132`. The batched ECB encrypt is
  `Cipher.getInstance("AES/ECB/NoPadding")` + `doFinal(counters)`
  (`CipherAdapter.kt:124-126`).
- iOS: `CipherAdapter.swift:119-170`. The batched ECB encrypt is `CCCrypt(...,
  kCCOptionECBMode, ...)` (`CipherAdapter.swift:148-157`).

Because CTR turns a block cipher into a stream cipher, **encrypt and decrypt are
the same operation** — XOR with the keystream both ways. The comments and
`FileCryptor` design rely on this (`FileCryptor.kt:11-13`,
`FileCryptor.swift:3-4`).

The `CipherAdapter` contract makes the position-addressability a hard rule:
`transform(bytes, filePosition)` must be a pure function of its arguments so the
player can seek anywhere without streaming from byte 0
(`CipherAdapter.kt:8-17`, `CipherAdapter.swift:5-11`).

### 2.2 The other schemes (context)

The scheme is chosen in Dart as a `sealed class CryptoScheme`
(`crypto_scheme.dart:10`) that serializes to `(type, params)`
(`crypto_scheme.dart:36-39`) and is resolved natively by a name→factory
`CipherRegistry` (`CipherAdapter.kt:28-51`, `CipherAdapter.swift:32-62`).
Built-ins registered by default (`CipherAdapter.kt:31-35`,
`CipherAdapter.swift:37-41`):

| Scheme | `type` | Security | Notes |
|--------|--------|----------|-------|
| `NoneScheme` | `none` | none | plaintext passthrough (`crypto_scheme.dart:43-51`, `NoneAdapter` `CipherAdapter.kt:53-56`) |
| `XorLegacyScheme` | `xorLegacy` | **not real security** | XORs bytes `[512, 512+256)` with `0xAB`, rest plain (`crypto_scheme.dart:57-79`, `CipherAdapter.kt:63-85`). Comment states "Not real security" (`crypto_scheme.dart:56`). |
| `AesCtrScheme` | `aesCtr` | real (confidentiality only) | described above |
| `ClearKeyScheme` | `clearKey` | Media3 CENC DRM | **Android only**; iOS throws `platformNotSupported` (`crypto_scheme.dart:99-100`). Built as a real DRM source, not through the cipher path (`PlayerInstance.kt:171-204`). |
| `CustomScheme` | adapter name | app-defined | app registers a native `CipherAdapter` (`crypto_scheme.dart:115-125`). |

### 2.3 The encryptor: turning a plaintext file into an encrypted one

Encryption at rest is a whole-file transform, driven from Dart by
`SecureVideoEncryptor` (`encryptor.dart:42`):

- `encrypt(input, output, scheme)` / `decrypt(...)` both call `_start`
  (`encryptor.dart:49-55`), which calls the Pigeon host API
  `startCrypto(input, output, scheme.type, scheme.params, encrypt)`
  (`encryptor.dart:62-63`).
- Because CTR/XOR are involutions, "encrypt" and "decrypt" run the *same*
  `adapter.transform` — the `encrypt` flag mostly documents intent. The native
  `FileCryptor` just streams the file through the adapter.
- Native side runs on a **background thread in 1 MB chunks**, constant memory
  for any file size: Android uses a single daemon executor
  (`FileCryptor.kt:16,27-29`), iOS a `.utility` `DispatchQueue`
  (`FileCryptor.swift:29,33`). The transform loop is `FileCryptor.kt:57-71` /
  `FileCryptor.swift:64-80`.
- Progress and errors flow back on the `EventChannel`
  `secure_video_player/crypto_events` (`encryptor.dart:45-46`, name in
  `protocol.dart:4`), filtered by `operationId` (`encryptor.dart:69-71`).
  Payload keys: `SvpCryptoEvents` (`protocol.dart:38-45`).
- Cancel deletes the partial output file natively (`CryptoOperation.cancel`
  `encryptor.dart:33`; native delete `FileCryptor.kt:58-64`,
  `FileCryptor.swift:65-71`). Any exception also deletes the half-written output
  (`FileCryptor.kt:75-78`).

### 2.4 The SVP protocol: what the "URI"/wire actually is

There are **two distinct things** people call "the protocol" here; keep them
separate:

**(a) The shared wire protocol constants.** A hand-mirrored set of string
constants that Dart, Kotlin, and Swift must all agree on: channel names, scheme
`type` strings, source-type strings, event names, and payload keys. Defined in
three files kept in sync by hand:

- Dart: `lib/src/protocol.dart` (`SvpChannels`, `SvpEvents`,
  `SvpCryptoEvents`, `SvpTrackTypes`).
- Android: `SvpProtocol.kt` (scheme types `:46-49`, source types `:52-55`).
- iOS: `SvpProtocol.swift` (scheme types `:45-49`, source types `:51-54`).

A crypto scheme crosses this wire as `(schemeType: String, schemeParams:
Map)` inside the Pigeon `CreateRequest`, plus `sourceType` +`source`. The
scheme's own `type`/`params` getters produce those values
(`crypto_scheme.dart:36-39`). Source types: `file`, `asset`, `url`,
`contentUri` (`SvpProtocol.kt:52-55`).

**(b) The iOS custom URL scheme `svp-encrypted://`.** This is a real URI, and
it exists only on iOS. It is a *trick* to force AVFoundation to route every byte
read through our delegate instead of reading the file itself:

- `CipherResourceLoaderDelegate.scheme = "svp-encrypted"`
  (`CipherResourceLoaderDelegate.swift:10`).
- `makeURL(filePath:)` builds `svp-encrypted://local/<absolute path>`
  (`CipherResourceLoaderDelegate.swift:84-90`).
- `PlayerInstance` opens that URL as an `AVURLAsset` and attaches the delegate
  (`PlayerInstance.swift:80-85`).

Android has **no** URI scheme trick. It builds a `CipherDataSource.Factory`
directly and wraps it in a `ProgressiveMediaSource`; the `MediaItem` URI is just
an ordinary `file://` or `content://` URI (`PlayerInstance.kt:154-157`).

### 2.5 Android read path — `CipherDataSource` (pull model)

`CipherDataSource` implements Media3's `DataSource` interface
(`CipherDataSource.kt:41-44`). ExoPlayer *pulls* bytes from it.

- `open(dataSpec)` (`CipherDataSource.kt:58-77`): opens a seekable
  `FileChannel`, allocates one reused **64 KB direct** `ByteBuffer`
  (`BUFFER_SIZE`, `CipherDataSource.kt:47,64`), sets `position =
  dataSpec.position` and physically seeks the channel there
  (`CipherDataSource.kt:66-67`). Remaining length uses
  `adapter.plaintextSize(...)` when the length is unset
  (`CipherDataSource.kt:69-73`).
- `read(target, offset, length)` (`CipherDataSource.kt:79-99`): reads up to
  `min(length, bytesRemaining, 64 KB)` (`:85`) into the direct buffer, copies to
  `target` (`:93`), then decrypts **in place** with
  `adapter.transform(target, offset, read, position)` (`:94`), and advances
  `position` (`:96`). That `position` is the absolute file offset — it is what
  feeds the counter math in §2.1.

**Seek → offset → counter:** an ExoPlayer seek causes a new `open(dataSpec)`
with a nonzero `dataSpec.position`, which becomes `position`, which becomes
`filePosition` in `transform`, which becomes `firstBlock = filePosition / 16`.
No re-streaming from zero — O(1) seek.

Two source openers (`CipherDataSource.Factory`, `CipherDataSource.kt:119-151`):
`forFile` (a `RandomAccessFile` channel, `:128-134`) and `forContentUri` (a
MediaStore `content://` descriptor via `ContentResolver`, `:137-149`). Both are
plain seekable regular files. Subtitles are loaded through a separate plain
`FileDataSource`, never the cipher (`PlayerInstance.kt:161-169`).

### 2.6 iOS read path — `CipherResourceLoaderDelegate` (push/request model)

`CipherResourceLoaderDelegate` implements `AVAssetResourceLoaderDelegate`
(`CipherResourceLoaderDelegate.swift:8`). AVFoundation *asks* it to satisfy
loading requests.

- `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)` returns `true`
  and dispatches the work to a serial queue
  (`CipherResourceLoaderDelegate.swift:22-28`). Returning `true` is the contract
  promise: "I will fulfill this request asynchronously."
- `contentInformationRequest` (`:42-46`): reports MIME type, `contentLength =
  adapter.plaintextSize(fileSize)` (`:44`), and crucially
  `isByteRangeAccessSupported = true` (`:45`) — this is what lets AVPlayer issue
  ranged reads and thus seek.
- `dataRequest` (`:48-70`): reads `requestedOffset` / `requestedLength` (or "to
  end of resource", `:53-57`), then loops in **512 KB** chunks (`chunkSize`,
  `:15,61`): `FileHandle.seek(toFileOffset:)` (`:62`), read, decrypt in place
  with `adapter.transform(&data, filePosition: position)` (`:65`), and
  `dataRequest.respond(with:)` (`:66`). Honors cancellation via
  `request.isCancelled` (`:60`).

**Seek → byte range → counter:** an AVPlayer seek produces a new
`loadingRequest` with a new `requestedOffset`; that offset is the
`filePosition` handed to `transform`, feeding the same counter math. Same O(1)
seek, arrived at through a different contract.

### 2.7 Cross-platform parity guarantees (and the gaps)

Guaranteed identical:

- **Byte-for-byte crypto output.** Same key/nonce → same keystream → same
  ciphertext, because both platforms implement the *exact* same
  `nonce||big-endian-counter` ECB construction (`CipherAdapter.kt:106-132` vs
  `CipherAdapter.swift:119-170`). A file encrypted on Android decrypts on iOS
  and vice versa. `plaintextSize` is identity on both (`CipherAdapter.kt:20`,
  `CipherAdapter.swift:15`), so no container/offset differences.
- **Same key/nonce validation** (16/32-byte key, 8-byte nonce) on both.
- **Same wire constants** for scheme types and event payloads (`SvpProtocol.kt`
  / `SvpProtocol.swift` / `protocol.dart`).
- **Decrypt-only-in-memory** invariant on both paths — no plaintext file is ever
  written during playback.

Real parity **gaps** found in code:

- `clearKey` is Android-only; iOS throws `platformNotSupported`
  (`crypto_scheme.dart:99-100`).
- `contentUri` source is Android-only: `SvpProtocol.kt:55` defines
  `SOURCE_CONTENT_URI`, but `SvpProtocol.swift:51-54` has no equivalent, and the
  iOS loader takes only a file path (`CipherResourceLoaderDelegate.swift:17`).
- Read chunk sizes differ: 64 KB (Android, `CipherDataSource.kt:47`) vs 512 KB
  (iOS, `CipherResourceLoaderDelegate.swift:15`). Functionally transparent, but
  a real IO-granularity difference.

---

## Tier 3 — PhD deep-dive

### 3.1 CTR keystream, formally

Let `E_k` be AES under key `k` (a block permutation on 128-bit blocks). Let the
nonce be the fixed 64-bit string `N`. Define the counter block for block index
`i ∈ {0, 1, …}`:

```
ctr(i) = N ‖ i                (128 bits: 64-bit N, then 64-bit big-endian i)
KS_i   = E_k(ctr(i))          (128-bit keystream block)
```

The keystream is the concatenation `KS = KS_0 ‖ KS_1 ‖ …`, and

```
ciphertext = plaintext ⊕ KS      (truncated to plaintext length)
plaintext  = ciphertext ⊕ KS      (identical operation)
```

The implementation realizes exactly this. `firstBlock = ⌊pos/16⌋` selects
`KS_{firstBlock}`, and `skip = pos mod 16` indexes into that block so an
unaligned read starts mid-block (`CipherAdapter.kt:108-109`,
`CipherAdapter.swift:122-123`). Multiple blocks are produced in one ECB call
over the concatenated counter buffer (`CipherAdapter.kt:113-126`,
`CipherAdapter.swift:126-160`) — AES-ECB of independent counter blocks *is* the
CTR keystream, which is why building CTR from ECB is legitimate here.

### 3.2 Why random access is O(1)

Keystream block `KS_i` depends only on `k`, `N`, and `i` — never on any earlier
byte. Therefore decrypting the byte at absolute offset `pos` requires computing
only `⌈(skip+len)/16⌉` AES blocks starting at `⌊pos/16⌋`, independent of `pos`
itself. Seeking to 90% of a 4 GB file costs the same as reading the first byte.
Both platforms exploit this identically: Android turns a seek into a new
`dataSpec.position` (`CipherDataSource.kt:66`); iOS turns it into a new
`requestedOffset` (`CipherResourceLoaderDelegate.swift:53`). This is precisely
the property that a CBC/CFB chained mode or a single-tag AEAD-over-whole-file
would destroy.

Counter space: the 64-bit big-endian block counter addresses `2^64` blocks =
`2^68` bytes ≈ 256 exabytes before it would wrap. No practical overflow inside a
single file. The nonce occupies the *high* 64 bits and is never incremented, so
there is no carry from counter into nonce.

### 3.3 Confidentiality guarantee (IND-CPA) and its exact preconditions

CTR mode is a textbook IND-CPA-secure encryption scheme **provided** the pair
`(k, per-block-counter)` is never reused, i.e. no `ctr(i)` value repeats under a
given key. Reduction sketch: if AES is a secure PRF, its outputs `E_k(ctr(i))`
are computationally indistinguishable from a random function evaluated at
distinct points; XORing a message with fresh pseudorandom bits is a one-time-pad
per block, hence IND-CPA.

The scheme here inherits that guarantee **only under two conditions that the
code does not enforce**:

1. **Unique (key, nonce) per file.** The nonce is 8 bytes and supplied by the
   caller (`AesCtrScheme.nonce`, `crypto_scheme.dart:89`). If two different
   videos are encrypted with the *same* key and *same* nonce, their keystreams
   are identical and `C1 ⊕ C2 = P1 ⊕ P2` — classic two-time-pad, catastrophic.
   Nothing in `AesCtrAdapter` checks for reuse; correctness of nonce management
   is entirely the caller's responsibility. There is no random nonce generation
   in this layer.
2. **Key secrecy.** IND-CPA models an adversary *without* the key. That is not
   the deployment reality here (see 3.5).

### 3.4 Malleability and the absence of authentication

This is the single most important security property to understand: **the scheme
provides confidentiality but no integrity and no authenticity.** There is no
MAC, no GCM tag, no AEAD — `plaintextSize` is the identity and no tag bytes are
stored or verified (`CipherAdapter.kt:20`, `CipherAdapter.swift:15`).

Consequences of raw CTR without a MAC:

- **Bit-flipping malleability.** Because `P = C ⊕ KS`, flipping bit `j` of the
  ciphertext flips bit `j` of the plaintext, deterministically, without knowing
  the key. An attacker who can write to the encrypted file can make controlled,
  targeted changes to the decrypted video bytes.
- **No tamper detection.** A corrupted or maliciously edited file will decrypt
  to garbage (or attacker-chosen deltas) and simply be handed to the decoder;
  the pipeline cannot tell valid plaintext from manipulated plaintext. The only
  backstop is the media decoder rejecting a malformed container.
- **No chosen-ciphertext (IND-CCA) resistance whatsoever.** Any padding-oracle
  or decoder-behavior oracle could in principle be leveraged; CTR alone offers
  no defense.

The fix, were integrity required, is Encrypt-then-MAC or an AEAD mode
(AES-GCM / ChaCha20-Poly1305) with the tag verified before the plaintext is
released to the decoder — at the cost of either per-chunk tags (to preserve
random access) or losing seekability with a single whole-file tag.

### 3.5 Threat model — what this actually protects against

**Protects against:** an adversary who obtains *only the encrypted file* and not
the key. On disk the file is indistinguishable from random (for `aesCtr`), so
file exfiltration alone — a stolen device backup, a copied gallery file, cloud
sync of the ciphertext — yields nothing without the key/nonce. This is
meaningful at-rest confidentiality. (`xorLegacy` and `none` give *no* such
protection and are explicitly labeled as such, `crypto_scheme.dart:56`.)

**Does NOT protect against:**

- **Rooted / jailbroken device.** The key and nonce are passed from Dart into
  the app process (`AesCtrScheme.params`, `crypto_scheme.dart:96`) and held in
  native memory inside the `AesCtrAdapter` instance (`CipherAdapter.kt:93-94`,
  `CipherAdapter.swift:100-101`). Root lets an attacker read that process
  memory, hook `CipherRegistry.create`, or hook `transform` directly.
- **Memory dump during playback.** Decrypted plaintext exists in RAM by design —
  the 64 KB `target` buffer on Android (`CipherDataSource.kt:80-94`) and the
  `Data` chunks on iOS (`CipherResourceLoaderDelegate.swift:63-66`), plus the
  key material. A core dump or debugger attach during playback recovers both
  plaintext frames and the key.
- **Instrumentation / Frida-style hooking.** The `CipherAdapter.transform`
  boundary is a clean single choke point an attacker can hook to siphon
  plaintext, precisely because the design centralizes decryption there
  (`CipherAdapter.kt:17`, `CipherAdapter.swift:9`).
- **Screen capture / recording.** This layer is cryptographic only; it does
  nothing about the rendered pixels. Preventing screenshots is a platform
  surface-flag concern (`FLAG_SECURE` on Android, screen-capture detection on
  iOS), out of scope for the cipher and not implemented here.
- **An attacker who has both file and key.** By definition, decryptable. Key
  distribution/attestation is out of scope.

In short: this is a **confidentiality-at-rest** control against file theft, not
a DRM/anti-capture system. `clearKey` (Android CENC DRM,
`PlayerInstance.kt:171-204`) is the only path that touches the platform's
hardware-backed DRM stack; the `aesCtr` path deliberately does not.

### 3.6 Side channels and minor observations

- The batched-ECB approach materializes the full keystream for a chunk in a heap
  buffer (`keystream`, `CipherAdapter.kt:126`, `CipherAdapter.swift:143`) then
  XORs byte-by-byte in an interpreted loop. JCE/CommonCrypto AES is
  constant-time on AES-NI hardware, but the surrounding allocation and the
  scalar XOR loop are not a hardened implementation — timing is data-independent
  here (pure XOR), so this is a performance note more than a leak.
- Android allocates a fresh `Cipher` object *per `transform` call* via
  `Cipher.getInstance` (`CipherAdapter.kt:124`) — one per 64 KB read. That is a
  provider-lookup and object-construction cost on the hot playback path (see
  Performance).

---

## Limitations (today)

1. **No integrity/authentication.** Raw AES-CTR, no MAC/AEAD. Tampering is
   undetectable and malleable (§3.4). `plaintextSize` identity confirms no tag
   is stored (`CipherAdapter.kt:20`, `CipherAdapter.swift:15`).
2. **Nonce management is the caller's problem.** No uniqueness check, no random
   nonce generation in this layer; (key, nonce) reuse silently breaks
   confidentiality (§3.3, `crypto_scheme.dart:89`).
3. **Key lives in process memory in the clear.** No keystore/Secure Enclave
   integration; adapter holds raw key bytes (`CipherAdapter.kt:93-94`,
   `CipherAdapter.swift:100-101`). Useless against root/memory dump (§3.5).
4. **`Cipher.getInstance` per read on Android** (`CipherAdapter.kt:124`) —
   repeated provider lookup/allocation on the playback hot path.
5. **Feature parity gaps:** `clearKey` and `contentUri` are Android-only
   (`crypto_scheme.dart:99-100`; `SvpProtocol.swift:51-54` lacks contentUri).
6. **Chunk-size asymmetry:** 64 KB Android vs 512 KB iOS
   (`CipherDataSource.kt:47`, `CipherResourceLoaderDelegate.swift:15`) — not a
   correctness issue, but IO behavior differs across platforms.
7. **Whole-file encrypt is single-threaded** (one daemon executor / one utility
   queue) — `FileCryptor.kt:27-29`, `FileCryptor.swift:29`.

---

## Performance: how to make it insane

Concrete, measurable changes ordered by expected win on the playback/transform
hot paths.

1. **Cache the AES engine on Android (biggest playback win).** Replace the
   per-read `Cipher.getInstance("AES/ECB/NoPadding")` (`CipherAdapter.kt:124`)
   with a single `Cipher` created once in `init()` and reused (or better, use
   `"AES/CTR/NoPadding"` with an `IvParameterSpec(nonce ‖ firstBlock)` and let
   JCE run the counter + XOR internally with AES-NI). Expected: eliminates one
   provider lookup + object alloc per 64 KB read — on the order of tens of
   thousands of allocations/minute during playback removed; measurable CPU and
   GC-pressure drop, especially on seek-heavy scrubbing.

2. **Use native CTR instead of ECB+manual XOR on iOS.** Replace the
   `kCCOptionECBMode` + scalar XOR (`CipherAdapter.swift:148-169`) with a
   `CCCryptorCreateWithMode(..., kCCModeCTR, ...)` cryptor seeded to the block
   offset, reusing the cryptor across chunks. Removes the separate keystream
   buffer allocation (`CipherAdapter.swift:143`) and the byte-wise XOR loop.
   Expected: fewer allocations and a single hardware-accelerated pass instead of
   two passes over the data.

3. **Kill the extra copy on Android.** `read()` currently copies channel → direct
   buffer → `target` then transforms in place (`CipherDataSource.kt:87-94`).
   Wrap `target` in a `ByteBuffer.wrap(target, offset, toRead)` and read the
   channel straight into it, then transform — removes one full-chunk memcpy per
   read. Expected: ~1 fewer 64 KB copy per read; noticeable at high bitrate.

4. **Vectorize / word-align the XOR.** Both platforms XOR one byte at a time
   (`CipherAdapter.kt:128-131`, `CipherAdapter.swift:163-169`). XOR 8 bytes at a
   time (Long/UInt64) with a byte remainder tail — roughly 8× fewer loop
   iterations on the XOR, which is the one part not covered by AES-NI.

5. **Tune/align chunk size.** Raise Android's 64 KB toward iOS's 512 KB
   (`CipherDataSource.kt:47`) to amortize per-read overhead and syscall count;
   benchmark against memory. Expected: fewer `read()`/`transform` invocations per
   second of video.

6. **Parallelize whole-file encryption.** CTR is embarrassingly parallel — block
   `i` is independent. `FileCryptor` could split the file into N ranges across a
   thread pool instead of the single daemon executor
   (`FileCryptor.kt:27-29`, `FileCryptor.swift:29`), giving near-linear speedup
   on multi-core devices for the one-time encrypt/decrypt operation.

7. **If integrity is ever added, use per-chunk AEAD** (e.g. AES-GCM per 64 KB /
   512 KB block with the block index in the AAD) rather than a whole-file tag, to
   keep the O(1) random access from §3.2 while gaining tamper detection.

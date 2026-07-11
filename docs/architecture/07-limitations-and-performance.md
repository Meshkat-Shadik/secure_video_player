# 07 — Limitations & Performance Roadmap

This is the honest cross-cutting synthesis: everything the system does **not** do
well today (each grounded in a `file:line`), followed by a prioritized roadmap of
optimizations — mechanism, expected gain, effort, risk — up to the "make it
insane" tier. Speculative numbers are marked *(estimate)*; they are engineering
judgment, not measurements.

Diagram: [`diagrams/07-perf-roadmap.drawio`](diagrams/07-perf-roadmap.drawio)

> **Status update (2026-07-11)** — the following P0 items described below have
> since been **implemented** (analyses kept for the record):
> cached AES `Cipher` instance (`CipherAdapter.kt`), zero-copy read into the
> caller's buffer (`CipherDataSource.kt`), position ticker gated on
> `isPlaying` (Android `PlayerInstance.kt`), NV12 video output + paused
> `CADisplayLink` (iOS `PlayerInstance.swift`). Line references in those
> sections describe the pre-fix code.

---

## Tier 1 — Explain it to a kid

Our movie machine works, but it's not perfect. Sometimes it does the same hard
math over and over when it could just remember the answer. Sometimes it copies a
bucket of water from one pail to another for no reason. And the Android version
knows a few tricks the iPhone version doesn't (and the other way around).

None of this breaks the movie — it just means the machine works harder and gets
hotter than it needs to. This page is the **to-do list** for making it faster and
fairer, sorted by "biggest win for least work" first.

---

## Tier 2 — The honest limitation inventory

### Security / crypto scheme properties

| Limitation | Where | Detail |
|-----------|-------|--------|
| Software decryption in-process | `CipherAdapter.kt`, `.swift` | Plaintext exists in decoder memory; a rooted device / attached debugger can read it. Confidentiality **at rest**, not anti-extraction. |
| No hardware DRM for own files | `PlayerInstance.kt:171` | The only hardware path is Media3 ClearKey (CENC), which is **Android-only** (`SecureVideoPlayerPlugin.swift:63`) and separate from this package's encryptor. No Widevine L1 / FairPlay integration. |
| CTR malleability, no integrity | `CipherAdapter.kt:106` | AES-CTR provides confidentiality only. There is no MAC/AEAD, so ciphertext tampering is undetected — a flipped ciphertext bit flips the corresponding plaintext bit. Corruption surfaces only as a decoder parse error (`PlayerInstance.kt:277`). |
| Nonce reuse is caller's burden | `crypto_scheme.dart:83` | Reusing a `(key, nonce)` pair across two files is the classic two-time-pad break. The API does not enforce uniqueness. |
| `xorLegacy` is not security | `crypto_scheme.dart:56` | Skip 512 B, XOR 256 B with `0xAB`. Backward-compat only. |

### Rendering / pixel path

| Limitation | Where | Detail |
|-----------|-------|--------|
| Extra memcpy in the read loop (Android) | `CipherDataSource.kt:89`–`94` | Ciphertext is read into a direct `ByteBuffer`, then `buf.get(target,…)` copies it into ExoPlayer's array *before* in-place decrypt. One redundant 64 KB copy per read. |
| Per-frame pixel-buffer copy (iOS texture) | `PlayerInstance.swift:119`–`127` | `copyPixelBuffer` returns a retained `CVPixelBuffer` each frame. IOSurface-backed, so cheap, but still a copy/retain per composited frame. |
| CPU keystream, no GPU offload | `CipherAdapter.kt:124` | AES runs on CPU (JCE/CommonCrypto). No GPU/NEON-batched decrypt for very high-bitrate 4K content. |

### Bridge / control plane

| Limitation | Where | Detail |
|-----------|-------|--------|
| Handlers on UI thread | doc 06; no `TaskQueue` in any `.g` file | `getMediaInfo` probes a file synchronously on the main thread (`SecureVideoPlayerPlugin.kt:234`). |
| No call coalescing | `controller.dart:266` | Fast scrub = one `seekTo` round trip per frame. |
| Stringly-typed events | `controller.dart:201` | Event payload keys are runtime-cast maps, not Pigeon types. |

### Buffering

| Limitation | Where | Detail |
|-----------|-------|--------|
| Back-buffer disabled | `PlayerInstance.kt:116` | `setBackBuffer(0, false)` — seeking backward re-reads and re-decrypts from the file rather than reusing buffered samples (a RAM-vs-CPU trade favoring low-RAM devices). |
| iOS buffering is opaque | `PlayerInstance.swift` | No `LoadControl` equivalent; `min/max/bufferForPlaybackMs` from `BufferConfig` are **ignored on iOS** — they only wire into Android's `DefaultLoadControl` (`PlayerInstance.kt:109`). AVPlayer self-tunes. |
| No adaptive tuning | `player_options.dart:33` | Buffer sizes are static config, not adjusted to measured bandwidth/decode headroom. |

### Platform feature gaps (Android vs iOS)

| Feature | Android | iOS | Evidence |
|---------|---------|-----|----------|
| ClearKey DRM | ✅ | ❌ `platformNotSupported` | `SecureVideoPlayerPlugin.swift:63` |
| External SRT/VTT subtitles | ✅ | ❌ throws | `PlayerInstance.kt:359` vs `SecureVideoPlayerPlugin.swift:166` |
| Video quality-ladder tracks | ✅ (HLS/DASH groups) | ❌ returns `[]` for `video` | `PlayerInstance.kt:321` vs `PlayerInstance.swift:312` |
| `content://` source | ✅ | ❌ | `CipherDataSource.kt:137`, `player_options.dart:18` |
| PiP | any mode (activity opt-in) | platformView only | `PlayerInstance.kt:383`; `PlayerInstance.swift:340` needs `AVPlayerLayer` |
| Screen-capture block | real `FLAG_SECURE` | best-effort text-field hack | `SecureVideoPlayerPlugin.kt:222` vs `.swift:191` |
| `BufferConfig` honored | ✅ | ❌ ignored | `PlayerInstance.kt:109` |

### Lifecycle / robustness

- **Background playback is best-effort.** Android keeps a `MediaSession` for
  lock-screen controls but has **no foreground `MediaSessionService`**, so
  aggressive process death stops playback (`PlayerInstance.kt:419` ponytail note).
- **Position ticker is fixed at 250 ms** on both platforms
  (`PlayerInstance.kt:99`, `PlayerInstance.swift:241`) — not adaptive to playback
  rate or paused state.

---

## Tier 3 — Prioritized performance roadmap

Ordered by impact-to-effort. Each entry: **Mechanism · Expected gain · Effort ·
Risk**. Diagram 07 plots these on an impact/effort map.

### P0 — High impact, low effort (do these first)

**1. Cache the AES `Cipher` object (kill per-chunk `getInstance`+`init`).**
- *Mechanism*: `AesCtrAdapter.transform` calls
  `Cipher.getInstance("AES/ECB/NoPadding")` and `cipher.init(ENCRYPT_MODE, keySpec)`
  on **every** read chunk (`CipherAdapter.kt:124`–`125`). Provider lookup + AES
  key-schedule expansion, thousands of times per second. Construct the `Cipher`
  once in `init()` and reuse; or switch to `AES/CTR/NoPadding` seeded with a
  per-position `IvParameterSpec` built from `nonce‖blockIndex`, letting the JCE do
  the counter increment.
- *Expected gain*: large CPU/battery reduction in the hot loop *(estimate: the
  dominant per-chunk cost today)*, most visible on low-end devices.
- *Effort*: low. *Risk*: low (behavior-identical; add a decrypt round-trip test).

**2. Zero-copy decrypt into ExoPlayer's buffer (Android).**
- *Mechanism*: replace the direct-buffer read + `buf.get(target,…)` copy with
  `channel.read(ByteBuffer.wrap(target, offset, toRead))`, then
  `adapter.transform(target, offset, read, position)` in place
  (`CipherDataSource.kt:87`–`94`). Eliminates one 64 KB memcpy per read.
- *Expected gain*: removes ~1 memcpy per chunk across the whole stream; frees the
  reused direct buffer allocation. *(estimate: modest CPU, meaningful at 4K
  bitrates)*.
- *Effort*: low. *Risk*: low (heap-array channel reads are fully supported).

**3. Tune / enlarge the read chunk and reconsider back-buffer.**
- *Mechanism*: Android reads 64 KB (`CipherDataSource.kt:47`); iOS reads 512 KB
  (`CipherResourceLoaderDelegate.swift:15`). Larger Android chunks amortize
  syscall + (post-fix #1) cipher overhead. Separately, `setBackBuffer(0,false)`
  (`PlayerInstance.kt:116`) forces re-decrypt on backward seek; a small back
  buffer trades RAM for skipping re-decrypt on scrub-back.
- *Expected gain*: fewer syscalls; smoother backward scrubbing. *(estimate)*.
- *Effort*: low. *Risk*: low-medium (back buffer raises RAM — gate behind
  `BufferConfig`, keep `lowRam()` at 0).

### P1 — High impact, medium effort

**4. Read-ahead decrypt pipelining.**
- *Mechanism*: today decrypt is synchronous inside the codec's read
  (`CipherDataSource.read`). Add a bounded producer thread that pre-reads and
  pre-decrypts the next chunks into a ring buffer while the codec consumes the
  current one, so decode never waits on IO+crypto latency.
- *Expected gain*: hides file-IO + crypto latency behind decode; fewer rebuffers
  at high bitrate *(estimate)*.
- *Effort*: medium. *Risk*: medium (thread-safety, seek invalidation of the
  read-ahead buffer, memory bound).

**5. Player prewarming / pooling for grids and lists.**
- *Mechanism*: `create()` builds and `prepare()`s the engine synchronously
  (`PlayerInstance.kt:108`, `SecureVideoPlayerPlugin.swift:99`). For the 4-player
  grid and list-recycling scenarios (`README.md:190`), keep a small pool of
  reusable `PlayerInstance`s, or use ExoPlayer's `PreloadManager` to warm the
  next item while the current plays.
- *Expected gain*: near-instant start on scroll; fewer surface allocations
  *(estimate)*.
- *Effort*: medium. *Risk*: medium (state reset correctness, texture reuse,
  dispose races — note the existing dispose-mid-create fix, `controller.dart:175`).

**6. Move slow bridge handlers to a Pigeon `TaskQueue`.**
- *Mechanism*: `getMediaInfo` runs on the UI thread (doc 06). Annotate it to run
  on a background `TaskQueue` so probing a large file never blocks compositing.
- *Expected gain*: eliminates probe-induced jank.
- *Effort*: medium (schema change + regenerate 3 outputs). *Risk*: low.

**7. Coalesce/debounce control calls.**
- *Mechanism*: drop intermediate `seekTo` targets during a drag, send the last
  (`controller.dart:266`). Fewer round trips on the UI thread.
- *Expected gain*: fewer main-thread hops while scrubbing.
- *Effort*: low-medium. *Risk*: low.

### P2 — "Make it insane" (high effort, high ceiling)

**8. Hardware-accelerated crypto explicitly.**
- *Mechanism*: AES-NI (x86) / ARMv8 Cryptography Extensions are already used
  *when the JCE/CommonCrypto provider picks them* — the batched single-`doFinal`
  design (`CipherAdapter.kt:92`, `.swift:97`) exists to let hardware AES kick in.
  Going further: pin a hardware-backed provider, or drop to a NEON/AES-NI intrinsic
  keystream generator via JNI/C for the counter blocks, decoupled from JCE
  overhead. Once #1 lands, measure before doing this — the provider may already
  saturate hardware AES.
- *Expected gain*: approaches memory-bandwidth-bound decrypt *(estimate)*.
- *Effort*: high (native intrinsics, per-arch). *Risk*: medium-high (correctness,
  portability).

**9. Zero-copy GPU texture path end-to-end.**
- *Mechanism*: Android's `SurfaceProducer` already renders decoder output
  straight to a GPU surface (`PlayerInstance.kt:126`) — no per-frame CPU copy. The
  remaining copy is iOS `copyPixelBuffer` (`PlayerInstance.swift:119`); it is
  IOSurface-backed (`kCVPixelBufferIOSurfacePropertiesKey`,
  `PlayerInstance.swift:97`) so already near-zero-copy, but a Metal-shared-texture
  path could remove the per-frame retain/copy entirely. Highest ceiling for 4K60.
- *Expected gain*: lower GPU/CPU per frame at high resolution *(estimate)*.
- *Effort*: high. *Risk*: high (Flutter texture-registry contract, color format).

**10. `io_uring`-style / vectored async IO for the decrypt reader.**
- *Mechanism*: the reader uses blocking `FileChannel.read` (Android,
  `CipherDataSource.kt:89`) / `FileHandle.readData` (iOS,
  `CipherResourceLoaderDelegate.swift:63`). On Linux/Android, batched async
  submission (`io_uring`, or `readv` with multiple in-flight requests) overlaps IO
  with decrypt more aggressively than a single blocking read; pairs naturally with
  read-ahead (#4).
- *Expected gain*: hides storage latency on slow flash *(estimate)*.
- *Effort*: high (native, platform-specific, needs benchmarking to justify).
  *Risk*: high.

**11. Codec-aware / adaptive buffering.**
- *Mechanism*: `BufferConfig` is static (`player_options.dart:33`) and **ignored
  on iOS**. Feed measured decode headroom and (for streaming) bandwidth into
  Android's `LoadControl`, and add an iOS buffering shim, adjusting buffer targets
  at runtime instead of fixed `min/max` ms.
- *Expected gain*: fewer rebuffers on variable networks/devices without
  over-buffering low-RAM phones *(estimate)*.
- *Effort*: high. *Risk*: medium.

**12. Adaptive position ticker.**
- *Mechanism*: the 250 ms ticker runs regardless of state
  (`PlayerInstance.kt:95`). Pause it when playback is paused / in PiP, and slow it
  when the app is backgrounded — fewer main-thread events and wakeups.
- *Expected gain*: minor CPU/battery, cleaner event stream.
- *Effort*: low. *Risk*: low. (Listed here as a cheap polish item.)

---

## Closing note on honesty

The architecture already made the two hardest calls correctly: **the pixel plane
never crosses the bridge** (only a `textureId` does), and **decrypt is kept off
the UI thread** on both platforms. Most remaining wins are about *not repeating
work* (P0 items 1–3) rather than restructuring. Do the P0 trio first, measure,
then decide whether the P2 "insane" tier is worth its risk for your bitrate and
device targets.

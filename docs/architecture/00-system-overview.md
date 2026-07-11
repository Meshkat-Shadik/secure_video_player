# 00 — System Overview

`secure_video_player` plays **encrypted-at-rest** video in Flutter. The
ciphertext lives on disk; plaintext is produced byte-by-byte *inside the native
read loop*, handed straight to the platform decoder, and never written back to
storage. This document is the map: what the system is, how one video frame
travels from encrypted bytes on disk to lit pixels on screen, and how the layers
fit together.

Read this first. Deeper subsystem docs (01–07) drill into each box drawn here.

Diagram: [`diagrams/00-system-overview.drawio`](diagrams/00-system-overview.drawio)

---

## Tier 1 — Explain it to a kid

Imagine you have a **treasure chest with a magic lock**. Inside is a cartoon
movie. If a robber steals the chest, all they see is scrambled junk — the movie
is locked up tight.

You have a **special key**. But here's the clever part: you never unlock the
whole chest and dump the movie on the floor where the robber could grab it.
Instead, there's a **magic window** on the chest. As the movie plays, the window
unscrambles *just the tiny piece playing right now*, shows it to you, and lets it
disappear. One little piece at a time. The robber never sees the whole movie
sitting out in the open — and neither does the floor (the disk).

- The **chest** is your encrypted video file.
- The **key** is your password (`CryptoScheme`).
- The **magic window** is the native decryptor (`CipherDataSource` on Android,
  `CipherResourceLoaderDelegate` on iOS).
- The **TV screen** is the Flutter widget showing the movie.
- The person building the app in Dart is like someone using a **remote control**
  (play, pause, jump ahead) — they press buttons, and the machine inside does the
  hard work.

Nobody ever leaves the whole unscrambled movie lying around. That's the whole
idea.

---

## Tier 2 — Engineer's view

### What the package is

A Flutter **federated-style plugin** (single package, per-platform native
implementations) that gives Dart code:

1. A **controller** API for playback (`SecureVideoController`,
   `lib/src/controller.dart:118`).
2. A **widget** that renders the video and ships full controls
   (`SecureVideoPlayer`, `lib/src/widgets/player_view.dart:47`).
3. An **encryptor** for turning plaintext files into ciphertext and back
   (`SecureVideoEncryptor`, `lib/src/encryptor.dart:42`).
4. **Pluggable crypto** via `CryptoScheme` (`lib/src/crypto_scheme.dart:10`),
   with `none`, `xorLegacy`, `aesCtr`, `clearKey`, and app-registered `custom`
   ciphers.

### The layer stack

| Layer | Responsibility | Key files |
|-------|----------------|-----------|
| **Flutter app** | Uses the controller + widget | `example/` |
| **Dart API** | State machine, event decoding, error typing | `lib/src/controller.dart`, `lib/src/widgets/player_view.dart` |
| **Pigeon bridge** | Typed control-plane RPC (create/play/seek…) | `pigeons/messages.dart`, `lib/src/messages.g.dart` |
| **Event channels** | Native → Dart events (per-player + crypto) | `lib/src/protocol.dart`, native `QueuingEventSink` |
| **Android platform** | Media3/ExoPlayer + custom `DataSource` | `android/.../PlayerInstance.kt`, `CipherDataSource.kt` |
| **iOS platform** | AVPlayer + resource-loader delegate | `ios/Classes/PlayerInstance.swift`, `CipherResourceLoaderDelegate.swift` |
| **Crypto** | Position-addressable in-place transforms | `CipherAdapter.kt` / `.swift` |
| **Render** | GPU texture or native platform view | Flutter `Texture` / `AndroidView` / `UiKitView` |

There are **two planes**:

- **Control plane** (Dart → native): synchronous-feeling method calls, one round
  trip each, over Pigeon `BasicMessageChannel`s. See doc 06.
- **Event plane** (native → Dart): a per-player `EventChannel`
  (`secure_video_player/events_<id>`, `lib/src/protocol.dart:8`) plus one shared
  crypto-progress channel (`secure_video_player/crypto_events`). Events are
  buffered natively by a `QueuingEventSink` until Dart subscribes, so the
  `initialized` event is never lost to a subscription race
  (`PlayerInstance.kt:39`, `PlayerInstance.swift:7`).

The **pixel plane** never crosses the bridge at all. Decoded frames flow from the
codec into a GPU-backed surface/texture; only a `textureId` (an integer handle)
is passed to Dart at create time.

### The journey of one frame

This is the load-bearing walkthrough. Trace it against the diagram.

**Setup (once):**

1. Dart: `controller.initialize(source, scheme, options)` builds a `CreateRequest`
   and calls `_api.create(...)` (`controller.dart:152`).
2. Bridge: Pigeon serializes the request and sends it on
   `dev.flutter.pigeon.secure_video_player.SecureVideoHostApi.create`
   (`messages.g.dart:557`). See doc 06 for the wire format.
3. Native (Android `create`, `SecureVideoPlayerPlugin.kt:110`): validates the
   scheme is registered, resolves the source path, allocates a `playerId`,
   creates a `SurfaceProducer` for texture mode, constructs a `PlayerInstance`,
   registers the per-player `EventChannel`, and returns
   `CreateResponse(playerId, textureId)`.
4. `PlayerInstance` builds a `ProgressiveMediaSource` whose `DataSource` is a
   `CipherDataSource` wrapping the encrypted file and the scheme's
   `CipherAdapter` (`PlayerInstance.kt:147`, `156`), sets it on an `ExoPlayer`,
   binds the texture surface (`PlayerInstance.kt:126`), and calls `prepare()`.
5. iOS mirror (`SecureVideoPlayerPlugin.swift:62` → `PlayerInstance.swift:57`):
   builds an `AVURLAsset` with a bogus `svp-encrypted://` URL so every read is
   routed through `CipherResourceLoaderDelegate`, attaches an
   `AVPlayerItemVideoOutput` for texture mode, and registers a `FlutterTexture`.

**Per frame (the hot loop):**

6. The codec asks the media pipeline for more bytes at some file position `p`.
7. **The magic window opens.** Android: ExoPlayer's loader thread calls
   `CipherDataSource.read(target, offset, length)` (`CipherDataSource.kt:80`). It
   reads up to 64 KB of *ciphertext* from the file channel into a reused direct
   buffer, copies into ExoPlayer's `target` array, then calls
   `adapter.transform(target, offset, read, position)` — decrypting **in place**
   (`CipherDataSource.kt:89`–`94`). iOS: AVFoundation asks
   `CipherResourceLoaderDelegate` for a byte range; it reads 512 KB chunks,
   `adapter.transform(&data, filePosition:)`, and `dataRequest.respond(with:)`
   (`CipherResourceLoaderDelegate.swift:59`–`70`).
8. **Decryption** is a position-addressable transform. For AES-CTR the keystream
   for the chunk is `AES-ECB(key, nonce‖blockIndex)` per 16-byte block, generated
   in one batched call and XORed over the ciphertext (`CipherAdapter.kt:106`,
   `CipherAdapter.swift:119`). Because it depends only on `(bytes, filePosition)`,
   a seek to anywhere is O(1) — no need to decrypt from byte 0. See doc 03.
9. The **plaintext bytes go straight to the platform decoder** (Media3
   `MediaCodec` / AVFoundation), which hardware-decodes them into a YUV/BGRA
   frame. Plaintext exists only transiently in decoder-owned memory; it is never
   written to disk.
10. The decoded frame lands on the **GPU surface**: Android renders into the
    `SurfaceProducer`'s `Surface` (`PlayerInstance.kt:126`); iOS copies the
    `CVPixelBuffer` out of `AVPlayerItemVideoOutput` on a `CADisplayLink` tick
    (`PlayerInstance.swift:119`, `130`).
11. **Flutter composites it.** In texture mode the widget is a
    `Texture(textureId:)` (`player_view.dart:266`) — the engine samples the GPU
    texture directly during compositing; the frame bytes never enter Dart. If the
    surface can't apply the video track's rotation, the widget wraps it in a
    `RotatedBox` using the `rotationCorrection` reported at init
    (`player_view.dart:270`, geometry logic in `PlayerInstance.kt:222`). In
    platformView mode the frame is drawn by the native `PlayerView` /
    `AVPlayerLayer` (`player_view.dart:292`/`298`).

**Meanwhile (side channels):**

- A 250 ms ticker on the native side pushes `position`/`buffered` events
  (`PlayerInstance.kt:95`, `PlayerInstance.swift:239`); the controller decodes
  them into `SecureVideoValue` (`controller.dart:201`) and `notifyListeners`
  rebuilds the widget's scrubber.
- Control-plane calls (`play`, `seekTo`, `setSpeed`…) each make one Pigeon round
  trip (`controller.dart:262`–`318`).

### Rendering: two modes

- **Texture** (`RenderMode.texture`): decoder → GPU texture → Flutter `Texture`
  widget. Composes like any widget (stacking, transforms, multiple players), and
  Flutter draws the controls. This is the default and the multi-player path.
- **PlatformView** (`RenderMode.platformView`): a real native view
  (`PlayerView` / `AVPlayerLayer`) embedded in the Flutter tree. Native controls,
  native PiP on iOS, but heavier composition. See docs 04/05.

### Error typing

Native codes are plain strings on the wire (`SvpProtocol.ERROR_*`,
`SvpProtocol.kt:67`). Control-plane failures come back as a Pigeon
`PlatformException` and are mapped to a typed `SecureVideoException`
(`errors.dart:18`, mapping via `SecureVideoErrorCode.fromWire`,
`errors.dart:13`). Asynchronous playback errors arrive as an `error` event and
are decoded in `controller.dart:241`.

---

## Tier 3 — Deep dive

### Why "decrypt in the read loop" is the whole architecture

The design constraint is: **plaintext must never persist to disk**, and playback
must survive on 1 GB-RAM devices while supporting arbitrary seeks. That rules
out the naive approaches:

- *Decrypt-to-temp-file then play*: leaks plaintext to storage; also doubles disk
  IO and wastes space.
- *Decrypt-whole-file-in-RAM*: impossible for GB-scale video on low-end phones.
- *Per-chunk Dart callback*: a Dart hop per 64 KB at MB/s throughput would stall
  playback (documented rationale, `README.md:110`). Hence ciphers are **native
  classes registered by name** and referenced from Dart by string.

The chosen model is a **streaming decrypt interposed at the platform's own IO
abstraction**:

- Android: ExoPlayer accepts a custom `DataSource`. `CipherDataSource` *is* the
  file, so decryption is invisible to the rest of the pipeline
  (`CipherDataSource.kt:41`).
- iOS: AVFoundation has no `DataSource`, but `AVAssetResourceLoaderDelegate` lets
  you serve byte ranges for a custom URL scheme. The
  `svp-encrypted://` scheme (`CipherResourceLoaderDelegate.swift:10`, `84`)
  forces every read through the delegate; `contentInformationRequest` advertises
  content type, plaintext length, and byte-range support so AVFoundation can seek
  (`CipherResourceLoaderDelegate.swift:42`).

The correctness precondition that makes seeking work is **position-addressability**:
`transform(bytes, filePosition)` must be a pure function of its arguments
(`CipherAdapter.kt:8`). Stream ciphers (CTR-style keystreams, positional XOR)
satisfy this; CBC does not (each block depends on the previous ciphertext), which
is why the custom-cipher contract explicitly forbids it (`README.md:120`).
Because keystream/XOR transforms are involutions, **encrypt == decrypt**, so the
same adapter serves both `SecureVideoEncryptor` and playback.

### Memory model

Per active player, decryption uses **one reused 64 KB direct buffer** on Android
(`CipherDataSource.kt:47`, `64`) — constant memory regardless of file size. iOS
reads in 512 KB slices bounded by the requested range
(`CipherResourceLoaderDelegate.swift:15`). The dominant memory cost is the
platform decoder's own buffers, tuned via `DefaultLoadControl`
(`PlayerInstance.kt:109`) / AVPlayer's implicit buffering, with
`BufferConfig.lowRam()` for constrained devices (`player_options.dart:41`).

### Two-plane concurrency

- **Control plane** handlers run on the platform **main/UI thread** (Pigeon
  registers no `TaskQueue` — see doc 06). They are cheap, non-blocking
  bookkeeping calls into `ExoPlayer`/`AVPlayer`.
- **Decrypt** runs off the main thread: on Android inside ExoPlayer's internal
  loader thread; on iOS on a per-player serial `DispatchQueue`
  (`PlayerInstance.swift:84`, `CipherResourceLoaderDelegate.swift:14`).
- **Events** are marshalled to the main thread before hitting the Flutter sink
  (`PlayerInstance.kt:65` `mainThread{}`, `PlayerInstance.swift:19`
  `DispatchQueue.main.async`), because `EventChannel` sinks must be called from
  the platform thread.

### Rotation as a cross-cutting invariant

Both platforms report a **display-oriented** size (rotation already applied to
width/height) plus a `rotationCorrection` telling Dart how far to rotate the raw
texture (`PlayerInstance.kt:222`, `PlayerInstance.swift:199`). This exists
because texture producers (Impeller's ImageReader-backed producer on Android,
`AVPlayerItemVideoOutput` on iOS) hand back *unrotated* pixel buffers, while
native platform views rotate themselves. Getting this wrong was a real
regression (CHANGELOG 0.3.1, `CHANGELOG.md:1`). Doc 04/05 cover the details.

---

## Limitations (today)

- **No hardware DRM path for the app's own files.** Encryption is a
  software stream cipher decrypted in the app process. The only hardware-DRM
  route is Media3 ClearKey (`PlayerInstance.kt:171`), which is Android-only
  (`SecureVideoPlayerPlugin.swift:63` throws `platformNotSupported`) and is CENC
  packaging, not this package's encryptor.
- **Plaintext is exposed in-process.** Decrypted bytes live in decoder memory and
  (on iOS) in `Data` handed to `dataRequest.respond` — a rooted device or a
  debugger attached to the app process can observe them. This is a
  confidentiality-at-rest scheme, not an anti-extraction/anti-screen-record one.
  Screen-capture blocking is best-effort: real `FLAG_SECURE` on Android
  (`SecureVideoPlayerPlugin.kt:222`), a secure-`UITextField` layer hack on iOS
  (`SecureVideoPlayerPlugin.swift:191`).
- **Feature parity gaps between platforms** (see doc 07 for the full matrix):
  external SRT/VTT subtitles and video quality ladders are Android-only
  (`SecureVideoPlayerPlugin.swift:166` throws; `PlayerInstance.swift:312`
  returns `[]` for `video`); ClearKey is Android-only; `contentUri` sources are
  Android-only (`player_options.dart:18`).
- **`xorLegacy` is not real security** — kept only for backward compatibility
  (`crypto_scheme.dart:56`).
- **Control-plane handlers run on the platform main thread**; a slow synchronous
  call (e.g. `getMediaInfo` probing a large file, `MediaInfoProbe`) blocks the UI
  thread for its duration (doc 06).

## Performance: how to make it insane

Cross-cutting roadmap lives in **doc 07**; the three highest-impact items:

1. **Cache the AES `Cipher` instance.** `AesCtrAdapter.transform` calls
   `Cipher.getInstance("AES/ECB/NoPadding")` **and** `cipher.init(...)` on *every*
   read chunk (`CipherAdapter.kt:124`). Each call pays a JCE provider lookup plus
   an AES key-schedule expansion — thousands of times per second at MB/s. Init the
   cipher once at adapter construction (or switch to `AES/CTR/NoPadding` with a
   per-position `IvParameterSpec`). *Estimated* large CPU/battery win on low-end
   devices; low effort; low risk.
2. **Decrypt directly into ExoPlayer's target buffer.** `CipherDataSource.read`
   currently reads ciphertext into a direct `ByteBuffer` and then `buf.get(target,
   …)` copies it into ExoPlayer's array before decrypting
   (`CipherDataSource.kt:89`–`94`). Reading via `ByteBuffer.wrap(target, offset,
   toRead)` and decrypting in place removes one 64 KB memcpy per read (true
   zero-copy decrypt). Low effort; low risk.
3. **Prewarm/pool players for grid & list scenarios.** `create()` builds and
   `prepare()`s the engine synchronously; scrolling a list (README's recycling
   stress, `README.md:190`) pays full startup each time. A small pool of reusable
   `PlayerInstance`s or ExoPlayer's `PreloadManager` cuts perceived start
   latency. Medium effort; medium risk (lifecycle/state reset).

Each item is expanded with mechanism, expected gain, effort, and risk in doc 07.

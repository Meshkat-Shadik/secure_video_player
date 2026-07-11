# 05 — iOS Platform (AVFoundation / AVPlayer)

> Scope: how the iOS side of `secure_video_player` turns a Pigeon `create` call
> into a running `AVPlayer`, delivers frames to a Flutter texture (via
> `AVPlayerItemVideoOutput`) or a native `AVPlayerLayer`, and streams playback
> events back to Dart via KVO / notifications. Crypto internals
> (`CipherResourceLoaderDelegate`, `SvpProtocol` cipher math) are doc 03 — here
> we only show where the player *wires them in*.
>
> Ground-truth sources: `SecureVideoPlayerPlugin.swift`, `PlayerInstance.swift`,
> `MediaInfoProbe.swift`, `ios/secure_video_player.podspec`. Every claim in
> Tier 2 cites `file:line`.
>
> **Status update (2026-07-11)**: the BGRA output format and always-on
> `CADisplayLink` described in §3.2/§limitations have since been **fixed** —
> the output now requests NV12 (`420YpCbCr8BiPlanarVideoRange`) and the display
> link pauses while playback is paused. Those sections are kept as the analysis
> that motivated the fix; their line references describe the pre-fix code.

---

## Tier 1 — Explain it to a kid

Same **magic TV box** story as Android, but the box is called **AVPlayer**.

Flutter (the remote) hands the box a scrambled movie and a secret key. But
AVPlayer is fussy: it won't read a file it doesn't recognize. So we play a
trick — we tell AVPlayer the movie lives at a made-up address, and we put a
little **doorman** (`CipherResourceLoaderDelegate`) at that address. Every time
AVPlayer asks the doorman for a piece of the movie, the doorman unscrambles that
piece with the key and hands it over. AVPlayer never knows the movie was locked.

To show the picture, the box copies each frame onto a little **photo card**
(a pixel buffer) and taps Flutter on the shoulder — *"new photo ready!"* —
using a heartbeat that ticks every screen refresh. Flutter grabs the card and
paints it. Or, if you prefer, the box paints directly onto its own window
(`AVPlayerLayer`) and Flutter just leaves a hole for it.

And like before, the box shouts notes back — *"ready!", "3 seconds!",
"1080p!", "done!"* — and when you close the movie, it lets go of everything.

---

## Tier 2 — Engineer's view

### 2.1 Plugin registration & the player registry

`SecureVideoPlayerPlugin` is `FlutterPlugin` + the Pigeon-generated
`SecureVideoHostApi` (`SecureVideoPlayerPlugin.swift:6`). `register(with:)`
(`:15-31`):

1. `SecureVideoHostApiSetup.setUp(binaryMessenger:api:)` — binds Pigeon
   commands (`:18-19`).
2. Crypto `FlutterEventChannel` on `SvpProtocol.channelCryptoEvents`, wrapped by
   a `SinkStreamHandler` over a `QueuingEventSink` (`:21-24`, handler
   `:266-281`).
3. Registers `PlayerPlatformViewFactory` under `SvpProtocol.platformViewType`
   (`:26-28`).
4. `observeAppLifecycle()` (`:30`, `:35-58`).

Registry mirrors Android — three fields keyed by `Int64`
(`SecureVideoPlayerPlugin.swift:8-10`): `players`, `eventChannels`,
`nextPlayerId` (`:95-96`).

> **Command vs. event split:** commands go over Pigeon `SecureVideoHostApi`;
> playback **events are plain dictionaries** over a per-player
> `FlutterEventChannel` named `secure_video_player/events_<playerId>`
> (`:111-115`, name at `SvpProtocol.swift:9`). Not Pigeon.

### 2.2 `create()` — from request to running player

`create(request:)` (`SecureVideoPlayerPlugin.swift:62-120`):

1. **ClearKey rejected** — `clearKey` throws `errorPlatformNotSupported`
   ("ClearKey DRM is Android-only. Use aesCtr on iOS.") (`:63-68`). This is the
   key platform divergence from doc 04.
2. **Adapter check** — non-registered scheme → `errorAdapterNotRegistered`
   (`:69-75`).
3. **Source resolution** — `sourceAsset` resolves through
   `registrar.lookupKey(forAsset:)` + `Bundle.main.path` (`:78-89`); non-URL
   sources get a file-exists check (`:90-93`).
4. **Player construction** — `PlayerInstance(...)`; a `CipherError` maps to
   `errorInvalidKey` (`:99-108`).
5. **Event channel** — per-player `FlutterEventChannel` + `SinkStreamHandler`
   (`:111-115`).
6. Returns `CreateResponse(playerId, textureId: instance.textureId >= 0 ? … :
   nil)` (`:117-119`) — `-1` sentinel becomes `nil` for the native-layer path.

### 2.3 AVPlayer / AVPlayerItem construction

`PlayerInstance.init` (`PlayerInstance.swift:57-115`):

- **Plaintext (`schemeNone`)** — a direct `AVURLAsset` from a file URL (or a
  remote URL string for `sourceUrl`); no loader delegate (`:72-77`).
- **Encrypted** — create the `CipherAdapter`, build a
  `CipherResourceLoaderDelegate`, point an `AVURLAsset` at a **custom-scheme
  URL** (`CipherResourceLoaderDelegate.makeURL`), and register the delegate on
  `asset.resourceLoader` on a dedicated serial queue `svp.loader.<id>`
  (`:78-86`). The delegate is held with a **strong** ref because
  `AVAssetResourceLoader` retains it only weakly (`:41-42` comment, field
  `:41`).
- `AVPlayerItem(asset:)` (`:88`) → `AVPlayer(playerItem:)` (`:89`);
  `actionAtItemEnd = .none` so looping is handled manually (`:90`).

### 2.4 The two render paths

**Texture path (`renderTexture`).** In `init` (`:94-105`): build an
`AVPlayerItemVideoOutput` requesting `kCVPixelFormatType_32BGRA` with
`kCVPixelBufferIOSurfacePropertiesKey` set, `item.add(output)`, then register
`self` (which conforms to `FlutterTexture`, `:32`) with the texture registry to
get `textureId` (`:102-104`).

Frame delivery is a **pull + notify** pair:
- `copyPixelBuffer()` (`FlutterTexture`, `:119-128`) is called by Flutter when it
  wants a frame; it pulls the newest buffer from the output for the current host
  time and returns it retained. Caches `latestPixelBuffer` so a redraw without a
  new frame still returns the last one (`:122-127`).
- `onDisplayLink(_:)` (`:130-136`) runs on a `CADisplayLink` and calls
  `textureRegistry.textureFrameAvailable(textureId)` whenever the output
  `hasNewPixelBuffer` — i.e. it tells Flutter *when* to call `copyPixelBuffer`.
  The display link is created in `sendInitializedIfNeeded` (`:221-225`).

**Native-layer path.** `PlayerPlatformView` hosts a `PlayerContainerView` whose
`layerClass` is `AVPlayerLayer` (`SecureVideoPlayerPlugin.swift:301-323`); the
factory assigns `containerView.playerLayer.player = instance.player` and, if
supported, creates the `AVPictureInPictureController` bound to that layer
(`:308-314`). No `AVPlayerItemVideoOutput`, no per-frame Flutter callback.

### 2.5 Rotation correction

`rotationCorrection()` (`PlayerInstance.swift:199-206`) returns the degrees Dart
must rotate the **texture** by. `presentationSize` is already
transform-applied, but `AVPlayerItemVideoOutput` hands back **unrotated** pixel
buffers, so texture mode needs a Dart `RotatedBox`; `AVPlayerLayer` rotates
itself and needs no correction (`:196-198` comment). The angle is derived from
the video track's `preferredTransform` via `atan2(t.b, t.a)`
(`:201-205`) — and it returns `0` unless `videoOutput != nil` (`:200`).

### 2.6 Events → Dart (KVO + notifications)

`observe()` (`PlayerInstance.swift:140-149`) registers KVO on the item/player and
one notification:

| Observed | Event emitted | Lines |
|----------|---------------|-------|
| item `status == .readyToPlay` | `initialized` (once, via `sendInitializedIfNeeded`) | `:156-158`, `:208-227` |
| item `status == .failed` | `error` — `svp`-domain → `errorFileNotFound`, else `errorCorruptStream` | `:159-167` |
| item `presentationSize` | `videoSize` (W,H + rotationCorrection) | `:168-176` |
| item `playbackBufferEmpty` | `buffering` | `:177-178` |
| item `playbackLikelyToKeepUp` | `ready` (after init) | `:179-182` |
| player `timeControlStatus` | `isPlayingChanged`; on playing starts ticker + unpauses display link | `:183-189` |
| `AVPlayerItemDidPlayToEndTime` | `onPlayedToEnd` → loop-seek or `completed` | `:146-149`, `:229-237` |

`sendInitializedIfNeeded` (`:208-227`) emits duration + size + rotation, then
(texture mode) creates the `CADisplayLink` on `.main`/`.common` and starts the
ticker.

The **position ticker** is a `Timer` at **0.25 s** (`:239-244`) → `sendPosition`
(`:257-269`) emitting `position` (current + buffered-time-range end) and polling
PiP (`checkPipState` `:249-255`). Like Android it starts on first play and is
**never invalidated until dispose** (see Limitations §L1).

`QueuingEventSink` (`PlayerInstance.swift:7-28`) buffers pre-listener events and
dispatches every `success` on `DispatchQueue.main` (`:19-23`).

### 2.7 Audio session & background

`setBackgroundPlayback(enabled)` (`SecureVideoPlayerPlugin.swift:182-189`) sets
the per-instance flag and, when enabling, activates the shared `AVAudioSession`
with category `.playback` (`:186-188`). App backgrounding auto-pauses non-
background players via `NotificationCenter` observers for
`didEnterBackground`/`willEnterForeground` (`:35-58`).

`setSecureFlag` (`:191-214`) has **no iOS equivalent of `FLAG_SECURE`**; it uses
the well-known secure-`UITextField` layer trick to blank the window in
screen recordings (`:196-207`).

### 2.8 MediaInfoProbe

`MediaInfoProbe.probe` (`MediaInfoProbe.swift:10-108`) builds an `AVURLAsset`
(plaintext direct, or through the same `CipherResourceLoaderDelegate` custom-URL
mechanism as playback, `:18-37`), then **synchronously blocks** the platform
thread on `loadValuesAsynchronously(forKeys: ["tracks","duration"])` with a
`DispatchSemaphore` and a **10 s timeout** (`:41-45`). It then reads
`preferredTransform` rotation and per-track format descriptions, decoding the
codec four-CC (`:59-99`, `fourCCString` `:115-121`). Failure to load tracks →
`errorCorruptStream` (`:48-52`).

### 2.9 Track selection

Tracks use AVFoundation **media selection groups** (`:302-336`), not track
overrides. `selectionGroup(for:)` maps `trackAudio → .audible`,
`trackSubtitle → .legible` (`:302-310`). `getTracks` enumerates
`group.options`, ids = option index (`:312-327`). **`video` returns empty** —
quality ladders are an HLS/DASH concept and local files expose one video track
(`:313-315` comment). `selectTrack` calls `item.select(option, in: group)` or
`item.select(nil, …)` to disable (`:329-336`).

### 2.10 Lifecycle & release

`dispose()` (`PlayerInstance.swift:349-367`): invalidate `positionTimer` and
`displayLink`, `player.pause()`, remove all 5 KVO observers + notification
observer, unregister the texture, `player.replaceCurrentItem(with: nil)`,
`events.endOfStream()`. Plugin `dispose(playerId:)` removes from the registry
and nils the event channel handler
(`SecureVideoPlayerPlugin.swift:130-133`).

### 2.11 Platform divergences from Android (doc 04)

| Capability | Android | iOS |
|------------|---------|-----|
| ClearKey DRM | supported (`DefaultDrmSessionManager`) | **rejected** (`create` `:63-68`) |
| Sideloaded SRT/VTT subtitles | `MergingMediaSource` | **not supported** — throws (`:166-176`) |
| Secure screen | `FLAG_SECURE` | secure-`UITextField` trick (`:191-214`) |
| Buffer tuning | `LoadControl` from `CreateRequest` | **not configurable** — `AVPlayer` internal |
| Screen brightness override | full override (incl. reset) | set only; no true override (`:225-233`) |

---

## Tier 3 — PhD deep-dive

### 3.1 The AVFoundation playback pipeline

```
AVURLAsset (custom svp:// URL)
   │  resourceLoader loadingRequest
   ▼
AVAssetResourceLoaderDelegate            ← CipherResourceLoaderDelegate
   │  (answers byte-range requests, decrypting on a serial queue)
   ▼
AVPlayerItem  (demux + decode, opaque)
   │
   ├──► AVPlayerLayer                     native compositing (own render server)
   └──► AVPlayerItemVideoOutput           CVPixelBuffer per frame → Flutter texture
```

AVFoundation is far more opaque than Media3: demuxing, decode, and buffering all
live behind `AVPlayerItem`, and the **only** public hooks are (a) the resource
loader for byte delivery and (b) the video output / layer for frames. There is
no `LoadControl` equivalent — buffering policy is AVPlayer-internal, driven by
`preferredForwardBufferDuration` (not set here). This is why the iOS side cannot
honour the Dart buffer knobs that Android does.

The resource-loader trick is the linchpin of secure playback: by giving the
asset a **custom URL scheme**, iOS routes every read through the delegate
(`PlayerInstance.swift:82-86`), which decrypts byte ranges on its serial queue.
As on Android, decryption operates on *compressed* bytes upstream of the
hardware decoder, so raw frames never pass through the cipher.

### 3.2 Flutter external-texture mechanics on iOS

The texture path stands on `CVPixelBuffer` + `IOSurface`:

- The output is configured with `kCVPixelBufferIOSurfacePropertiesKey`
  (`PlayerInstance.swift:97`), so each `CVPixelBuffer` is backed by an
  **`IOSurface`** — a kernel-shared, GPU-mappable buffer.
- `copyPixelBuffer()` returns that buffer to Flutter (`:119-128`). The Flutter
  engine wraps the `IOSurface` as a **Metal texture** and composites it — the
  pixels are shared, not memcpy'd across the process boundary.
- Cadence is driven by a **`CADisplayLink`** (`:222-224`) synced to the display
  refresh (60/120 Hz). Each tick checks `output.hasNewPixelBuffer(forItemTime:)`
  using a host-time→item-time mapping (`itemTime(forHostTime:)`, `:121`,
  `:132`) and only signals Flutter when a genuinely new frame exists — the
  correct A/V-sync-aware pull model.

**The BGRA cost.** The output requests `kCVPixelFormatType_32BGRA` (`:96`).
Hardware H.264/HEVC decoders emit **biplanar YUV (NV12,
`420YpCbCr8BiPlanarVideoRange`)**. Requesting 32BGRA forces a **YUV→BGRA color
conversion for every frame** inside AVFoundation before the buffer reaches
`copyPixelBuffer`. For 4K60 that is a non-trivial per-frame GPU/CPU cost and a
larger buffer (4 bytes/px vs. 1.5). See Performance §P1.

### 3.3 Where copies / hops actually happen

| Stage | Copy? | Thread / queue |
|-------|-------|----------------|
| File → `CipherResourceLoaderDelegate` | read + decrypt (doc 03) | `svp.loader.<id>` serial queue |
| decode → YUV → **BGRA convert** | **per-frame color-convert copy** | AVFoundation internal |
| `CVPixelBuffer`(IOSurface) → Flutter Metal texture | zero-copy (shared IOSurface) | GPU |
| `copyPixelBuffer` retain | pointer retain, no pixel copy (`:127`) | Flutter raster thread |
| KVO/notification → event dict | small serialize + `DispatchQueue.main` | main |
| `CADisplayLink` tick | callback on `.main` run loop | main |

The frame-sized cost unique to iOS is the **BGRA conversion** (§3.2). Everything
after the pixel buffer is IOSurface-shared. Main-thread pressure comes from
three sources on `.main`: the display link, the 0.25 s position `Timer`, and the
`QueuingEventSink.success` dispatch (`:19-23`).

### 3.4 Looping & seek semantics

`actionAtItemEnd = .none` (`:90`) disables AVPlayer's built-in end behaviour;
`onPlayedToEnd` (`:229-237`) either seeks to `.zero` and restores
`desiredRate`, or pauses + emits `completed`. Seeks use `toleranceBefore/After
= .zero` (`:283-286`) — **exact** frame-accurate seeking, which forces the
decoder to walk from the prior keyframe to the target, more expensive than a
tolerant seek but precise for scrubbing.

---

## Limitations (today)

- **L1 — Ticker + display link never pause.** The 0.25 s `Timer`
  (`PlayerInstance.swift:239-244`) is never invalidated until dispose, and the
  `CADisplayLink` is only ever *unpaused* (`:188`) — never re-paused on
  pause/stop. A paused player keeps ticking the display link at 60/120 Hz and
  emitting ~4 position events/sec. This is a concrete CPU/battery leak.
- **L2 — Per-frame BGRA conversion.** `kCVPixelFormatType_32BGRA` (`:96`) forces
  a YUV→BGRA convert every frame in texture mode.
- **L3 — No buffer tuning.** iOS ignores the Dart buffer knobs; AVPlayer
  internal policy only (§3.1).
- **L4 — Probe blocks the platform thread up to 10 s.** The synchronous
  semaphore wait in `MediaInfoProbe.probe` (`:41-45`) can stall the Pigeon
  platform thread on a slow/large file.
- **L5 — No sideloaded subtitles, no ClearKey.** Both throw
  `errorPlatformNotSupported` (`:166-176`, `:63-68`).
- **L6 — `video` track list is always empty** for local files (`:313-315`).
- **L7 — `setSecureFlag` uses an undocumented `UITextField` layer trick**
  (`:196-207`) that Apple can break in any iOS release; it is best-effort.
- **L8 — Deprecated synchronous asset APIs.** `item.asset.tracks(...)`
  (`:201`, MediaInfoProbe `:59`) is the pre-iOS-16 sync API; on newer OSes this
  can log/deprecate and should move to `load(.tracks)`.

## Performance: how to make it insane

- **P1 — Drop the BGRA conversion** *(biggest win)*. Request
  `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12) from
  `AVPlayerItemVideoOutput` (`:95-99`) and do the YUV→RGB in Flutter's texture
  shader. Removes a full per-frame color-convert and cuts the shared buffer to
  ~1.5 bytes/px — largest sustained-4K60 GPU/bandwidth saving available on iOS.
- **P2 — Pause the display link and ticker when not playing.** In the
  `timeControlStatus` handler (`:183-189`), set `displayLink?.isPaused = true`
  and invalidate/suspend the `Timer` when not `.playing`. Eliminates 60–120 Hz
  idle callbacks + ~4 events/sec/idle player (fixes L1).
- **P3 — Make the probe non-blocking.** Replace the semaphore wait
  (`MediaInfoProbe.swift:41-45`) with `AVAsset.load(.tracks, .duration)`
  (async/await) so `getMediaInfo` never parks the platform thread for up to 10 s.
- **P4 — Reuse the pixel buffer / avoid redundant `copyPixelBuffer`.** Only
  signal `textureFrameAvailable` on genuinely new frames (already gated at
  `:133`) and consider a `CVMetalTextureCache` to bind the IOSurface once rather
  than per pull.
- **P5 — Expose `preferredForwardBufferDuration`** on the `AVPlayerItem` so the
  Dart buffer options have an effect on iOS too, closing the P/L gap with
  Android's `LoadControl`.

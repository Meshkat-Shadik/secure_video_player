# 04 — Android Platform (Media3 / ExoPlayer)

> Scope: how the Android side of `secure_video_player` turns a Pigeon `create`
> call into a running ExoPlayer, pushes frames to a Flutter texture (or a native
> `PlayerView`), and streams playback events back to Dart. Crypto internals
> (`CipherDataSource`, `SvpProtocol` cipher math) are covered in doc 03 — here we
> only show where the player *wires them in*.
>
> Ground-truth sources: `SecureVideoPlayerPlugin.kt`, `PlayerInstance.kt`,
> `MediaInfoProbe.kt`, `android/build.gradle.kts`. Every claim in Tier 2 cites
> `file:line`.

---

## Tier 1 — Explain it to a kid

Imagine you have a **magic TV box**. Flutter is the remote control. When you
press "play a movie", the remote whispers to the box: *"here is the movie file,
here is the secret key to unlock it, and please paint the picture onto this
window."*

The box (**ExoPlayer**) opens the file, unscrambles it page by page, and turns
the scrambled squiggles into pictures. It paints those pictures onto a special
**glass pane** (the *texture*) that Flutter is holding up. Flutter never touches
the movie itself — it just holds the glass and watches the box paint on it.

While the movie plays, the box keeps shouting little notes back to the remote:
*"I'm ready!", "I'm at 3 seconds!", "the picture is 1920×1080!", "I finished!"*.
The remote uses those notes to move the little progress bar.

When you close the movie, the box is told to **let go of everything** — put down
the glass, close the file, forget the key — so nothing is left running in the
background eating batteries.

---

## Tier 2 — Engineer's view

### 2.1 Plugin registration & the player registry

`SecureVideoPlayerPlugin` is a single object that plays three roles at once —
`FlutterPlugin`, `ActivityAware`, and the Pigeon-generated `SecureVideoHostApi`
(`SecureVideoPlayerPlugin.kt:22`).

On `onAttachedToEngine` it does three things
(`SecureVideoPlayerPlugin.kt:63-81`):

1. `SecureVideoHostApi.setUp(binaryMessenger, this)` — binds the Pigeon method
   channel so Dart command calls (`play`, `seekTo`, `getTracks`…) dispatch to
   this object (`:66`).
2. Registers one **EventChannel** for crypto progress on
   `SvpProtocol.CHANNEL_CRYPTO_EVENTS`, fed by a `QueuingEventSink`
   (`:68-75`).
3. Registers the `PlayerPlatformViewFactory` under
   `SvpProtocol.PLATFORM_VIEW_TYPE` for the native-view render mode
   (`:77-80`).

The registry is three plain maps keyed by a monotonically increasing `Long`
player id (`SecureVideoPlayerPlugin.kt:28-30`):

| Field | Purpose |
|-------|---------|
| `players: Map<Long, PlayerInstance>` | live native players (`:28`) |
| `eventChannels: Map<Long, EventChannel>` | per-player event channel (`:29`) |
| `nextPlayerId: Long = 1` | id allocator, `nextPlayerId++` (`:30`, `:129`) |

> **Command vs. event split (important):** commands travel over the *Pigeon*
> `SecureVideoHostApi` method channel; playback **events do not use Pigeon** —
> they are plain `Map` payloads pushed over a per-player `EventChannel` named
> `secure_video_player/events_<playerId>` (`SecureVideoPlayerPlugin.kt:160-169`,
> channel name at `SvpProtocol.kt:11`). Doc 06 covers the Pigeon bridge; this
> doc covers the event side.

### 2.2 `create()` — from request to running player

`create(request: CreateRequest)` (`SecureVideoPlayerPlugin.kt:110-172`):

1. **Scheme validation** — non-`clearKey` schemes must have a registered
   `CipherAdapter` or it throws `ERROR_ADAPTER_NOT_REGISTERED` (`:112-116`).
2. **Source resolution** — `SOURCE_ASSET` is copied out of the APK into
   `cacheDir/svp_assets/…` via `copyAssetToCache` (`:118-121`, `:174-184`);
   URL / `content://` sources are left as-is and skip the file-exists check
   (`:122-127`).
3. **Texture allocation** — if `renderMode == RENDER_TEXTURE`, a
   `SurfaceProducer` is created from the Flutter `textureRegistry`
   (`:130-132`). Otherwise `surfaceProducer` is `null` and the frame path is a
   native `PlayerView` (§2.5).
4. **Player construction** — a `PlayerInstance` is built (`:134-153`). If the
   adapter rejects the scheme params it throws `IllegalArgumentException`, which
   is caught, the surface released, and re-thrown as `ERROR_INVALID_KEY`
   (`:154-157`) — this is the fix for the "release native player when controller
   is disposed mid-create" leak.
5. **Event channel wiring** — a per-player `EventChannel` is created and its
   `StreamHandler` binds the instance's `QueuingEventSink` (`:160-169`).
6. Returns `CreateResponse(playerId, textureId = surfaceProducer?.id())`
   (`:171`) — `textureId` is `null` in native-view mode.

### 2.3 ExoPlayer construction (Media3 1.10.1)

All Media3 deps are pinned to **1.10.1** (`android/build.gradle.kts:74-80`:
`media3-exoplayer`, `-dash`, `-hls`, `-datasource`, `-common`, `-ui`,
`-session`). `minSdk = 24`, `compileSdk = 36` (`build.gradle.kts:32,54`).

`PlayerInstance.init` (`PlayerInstance.kt:108-134`) builds the player:

```
DefaultLoadControl.Builder()
    .setBufferDurationsMs(minBufferMs, maxBufferMs, bufferForPlaybackMs,
                          DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
    .setBackBuffer(0, false)          // <-- no back-buffer retained
    .build()
ExoPlayer.Builder(context)
    .setLoadControl(loadControl)
    .setSeekBackIncrementMs(5000)
    .setSeekForwardIncrementMs(5000)
    .build()
```

- The three buffer durations come straight from the `CreateRequest`
  (`PlayerInstance.kt:109-115`) — i.e. they are **caller-controlled** from Dart
  `player_options`, not hardcoded here.
- `setBackBuffer(0, false)` (`:116`) means **zero** media is kept behind the
  playhead → a backward seek re-reads (and re-decrypts) from source. See
  Limitations §L2.
- After building: `addListener(this)` (`:125`), `setVideoSurface(surface)` for
  the texture path (`:126`), `setMediaSource(buildMediaSource())` (`:128`),
  repeat mode from `looping` (`:129`), volume (`:130`), optional start-seek
  (`:131`), `playWhenReady = autoPlay` (`:132`), `prepare()` (`:133`).

### 2.4 Media-source factory selection

`buildMediaSource()` (`PlayerInstance.kt:138-159`) picks a source graph by
scheme + source type:

| Condition | Source graph | Lines |
|-----------|--------------|-------|
| `scheme == clearKey` | `buildClearKeySource()` (DRM, DASH or Progressive) | `:139`, `:171-204` |
| `scheme == none` **and** `SOURCE_URL` | `DefaultMediaSourceFactory(DefaultDataSource.Factory)` — container sniffing (progressive / HLS / DASH) | `:141-145` |
| encrypted file | `ProgressiveMediaSource.Factory(CipherDataSource.Factory.forFile(...))` | `:147-158` |
| encrypted `content://` | `ProgressiveMediaSource.Factory(CipherDataSource.Factory.forContentUri(...))` | `:148-157` |

`CipherDataSource.Factory` is the only wiring point into the crypto layer
(`:147-153`) — the player treats it as an opaque `DataSource.Factory`; how it
decrypts is doc 03.

**Subtitle merging** — `mergeWithSubtitles` (`:161-169`) wraps the video source
in a `MergingMediaSource` alongside one `SingleSampleMediaSource` per sideloaded
subtitle, built on a **plain `FileDataSource.Factory`** (`:165`) — subtitles are
plaintext and deliberately bypass the cipher.

**ClearKey DRM path** — `buildClearKeySource` (`:171-204`) builds a JWK set from
the `keys` map (`:172-185`), wraps it in a `LocalMediaDrmCallback` (`:186`), and
constructs a `DefaultDrmSessionManager` bound to `C.CLEARKEY_UUID` via
`FrameworkMediaDrm.DEFAULT_PROVIDER` (`:187-189`). `.mpd` sources use
`DashMediaSource`, everything else `ProgressiveMediaSource`, both with
`setDrmSessionManagerProvider` (`:195-203`). ClearKey is Android-only (iOS
rejects it — see doc 05).

### 2.5 The two render paths

**Texture path (default `RENDER_TEXTURE`).**
`textureRegistry.createSurfaceProducer()` (`SecureVideoPlayerPlugin.kt:131-132`)
→ `player.setVideoSurface(surfaceProducer.surface)`
(`PlayerInstance.kt:126`). ExoPlayer's `MediaCodecVideoRenderer` decodes
straight into that `Surface`; Flutter composites the resulting texture by
`textureId`. No native View is involved.

**Native-view path (`RENDER_PLATFORM_VIEW`).**
`PlayerPlatformViewFactory` (`SecureVideoPlayerPlugin.kt:299-318`) creates a
Media3 `PlayerView` with `useController = true` and
`SHOW_BUFFERING_WHEN_PLAYING`, and attaches the existing `player`
(`:305-310`). `dispose()` detaches by setting `playerView.player = null`
(`:313`) — it does **not** release the player (the registry owns lifecycle).

**Rotation correction** — `displayGeometry()` (`PlayerInstance.kt:222-231`)
reports `(width, height, rotationCorrection)`. Media3 already swaps W/H for
90/270 rotations, so `videoSize` *is* the display size (`:214-221` comment
documents the past SVP-rotation bug). If the surface itself applies the buffer
transform (`surfaceProducer.handlesCropAndRotation()`), correction is `0`;
otherwise Dart must apply a `RotatedBox` using `videoFormat.rotationDegrees`
(`:225-229`).

### 2.6 Events → Dart

`PlayerInstance` implements `Player.Listener`. Listener callbacks convert to
`Map` payloads and push through the `QueuingEventSink`:

| Listener callback | Event(s) emitted | Lines |
|-------------------|------------------|-------|
| `onPlaybackStateChanged(STATE_READY)` | `initialized` (first time, + duration) or `ready`; starts 250 ms position ticker | `:243-254` |
| `onPlaybackStateChanged(STATE_BUFFERING / ENDED)` | `buffering` / `completed` | `:255-256` |
| `onIsPlayingChanged` | `isPlayingChanged` + immediate `sendPosition()` | `:261-264` |
| `onVideoSizeChanged` | `videoSize` (guarded W,H>0) | `:266-270` |
| `onPlayerError` | `error` with mapped code (file-not-found / DRM / corrupt / unknown) | `:272-286` |

The **position ticker** (`:95-101`) runs on the main-thread `Handler` every
**250 ms**, emitting `position` (current + buffered) and polling PiP state
(`sendPosition` `:288-294`, `checkPipState` `:407-414`). It starts when the
player first reaches `STATE_READY` and **runs until dispose** — it is not gated
on play/pause (see Performance §P1).

`QueuingEventSink` (`PlayerInstance.kt:39-69`) buffers events before the Dart
listener attaches and marshals every delivery onto the main thread
(`:65-68`) — a real main-thread hop per event.

### 2.7 MediaSession & background

`setBackgroundPlayback(true)` lazily creates a `MediaSession`
(`PlayerInstance.kt:416-429`) giving lock-screen / media-button controls. The
`ponytail:` comment at `:419-421` flags that surviving process death would need
a `MediaSessionService` + foreground notification (not implemented). App
backgrounding auto-pauses non-background players via
`ActivityLifecycleCallbacks` (`SecureVideoPlayerPlugin.kt:33-59`).

### 2.8 MediaInfoProbe

`MediaInfoProbe.probe` (`MediaInfoProbe.kt:39-116`) reads container + per-stream
metadata **without writing plaintext to disk**. It wraps the file in a
`CipherMediaDataSource` (`:18-37`) whose `readAt` decrypts each block in place
via `adapter.transform(buffer, offset, read, position)` (`:25-33`). Two passes:

- `MediaExtractor` for per-track formats (mime, W/H, frame rate, bitrate,
  sample rate, channels, language) (`:51-84`).
- `MediaMetadataRetriever` for container mime, rotation, total bitrate,
  fallback duration (`:89-107`).

Requires API 23+ (`MediaDataSource`) — throws `ERROR_PLATFORM_NOT_SUPPORTED`
below that (`:40-43`). Note it creates a **fresh adapter per pass** (`:52`,
`:90`).

### 2.9 Track selection

`getTracks(type)` (`PlayerInstance.kt:321-341`) walks `player.currentTracks`
groups filtered by `C.TRACK_TYPE_*`, encoding each track id as
`"groupIndex:trackIndex"`. `selectTrack` (`:343-357`) rebuilds
`trackSelectionParameters` with `clearOverridesOfType` then either disables the
type (null → off for subtitles / auto for A/V) or applies a
`TrackSelectionOverride(group.mediaTrackGroup, trackIndex)` (`:354`).

### 2.10 Lifecycle & release

`dispose()` (`PlayerInstance.kt:431-441`) is the full teardown: remove ticker
callbacks, release `MediaSession`, remove listener, `stop()`,
`clearVideoSurface()`, `player.release()`, `surfaceProducer.release()`,
`events.endOfStream()`. Plugin-level `dispose(playerId)` removes from the
registry and tears down the event channel (`SecureVideoPlayerPlugin.kt:189-192`);
`onDetachedFromEngine` disposes **all** players (`:83-89`).

---

## Tier 3 — PhD deep-dive

### 3.1 The Media3 rendering pipeline

Media3's playback graph is a pull pipeline:

```
DataSource (CipherDataSource)          byte stream, decrypted on read
   │  read(offset,len)
   ▼
MediaSource (ProgressiveMediaSource)   extracts elementary streams
   │  SampleStream per track
   ▼
Renderer (MediaCodecVideoRenderer /    dequeues samples, feeds MediaCodec
          MediaCodecAudioRenderer)
   │  input buffers
   ▼
MediaCodec (HW decoder)                decodes to a Surface (video) / PCM (audio)
   │  onOutputBufferAvailable → releaseOutputBuffer(render=true)
   ▼
Surface  (Flutter SurfaceProducer  OR  PlayerView's SurfaceView)
```

The crucial property for a *secure* player: with a HW `MediaCodec` writing into
a `Surface`, decoded frames **never enter the JVM heap** — they live in
gralloc/graphics memory and are consumed as a GPU texture. Decryption happens
one layer earlier, at `DataSource.read`, on *compressed* bytes (a few MB/s),
not on raw frames (hundreds of MB/s). This is why the cipher can be a cheap
per-read XOR/CTR transform and still sustain 4K playback.

### 3.2 LoadControl buffering theory & the configured values

`DefaultLoadControl` implements a **dual-watermark** buffering policy over four
quantities, all set here from the `CreateRequest`
(`PlayerInstance.kt:109-115`):

- `minBufferMs` — low watermark. Below it, the loader keeps fetching.
- `maxBufferMs` — high watermark. Above it, loading pauses (back-pressure) so
  we don't buffer the whole file into RAM.
- `bufferForPlaybackMs` — how much must be buffered before playback *starts*
  from idle. Small → fast start, more likely to stall.
- `DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS` — the (larger) threshold to
  *resume* after a stall; kept at the Media3 default (`:114`) to avoid
  stall-oscillation.

Because these are surfaced to Dart, the app can trade **startup latency vs.
stall risk vs. memory** per source. The theory: the player is a leaky bucket —
`min`/`max` bound the bucket, `bufferForPlayback*` set the drain-start levels.
For a *local decrypted file* the "network" is disk + cipher, so large buffers
mostly cost RAM, not smoothness.

`setBackBuffer(0, false)` (`:116`) sets the retained-behind-playhead buffer to
zero. Formally: the player keeps only `[playhead, playhead+bufferedAhead]` of
sample data. A backward seek to `t < playhead - 0` is always a cache miss →
`CipherDataSource` re-opens and re-decrypts from `t`. This is a memory/latency
trade the plugin currently resolves entirely toward memory.

### 3.3 Flutter external-texture mechanics on Android

`SurfaceProducer` abstracts two backends:

- **SurfaceTexture / GL backend (Skia).** The `Surface` wraps a
  `SurfaceTexture` bound to a GL **external OES texture**
  (`GL_TEXTURE_EXTERNAL_OES`). `MediaCodec` renders into the producer buffer;
  Flutter samples the OES texture in its GL pipeline. Zero CPU copy; the codec's
  crop/rotation transform is available via `SurfaceTexture.getTransformMatrix`,
  which is why `handlesCropAndRotation()` can return true — the transform is
  applied at sample time on the GPU.
- **ImageReader backend (Impeller / Vulkan default).** The producer is backed by
  an `ImageReader`; frames arrive as `HardwareBuffer`s imported as Vulkan/Metal
  images. Here `handlesCropAndRotation()` may be **false**, so the texture holds
  *raw unrotated* frames and Dart must wrap the widget in a `RotatedBox`
  (`PlayerInstance.kt:222-231` + comment `:214-221`). That extra Dart-side
  rotation is a composited transform, not a pixel copy, but it does force the
  frame through the widget transform each layout.

Either way the decoded pixels are never memcpy'd through Dart — the only Dart
traffic is the small event `Map`s. **Main-thread hops** are: (a) every event via
`QueuingEventSink.mainThread` (`:65-68`), and (b) the 250 ms ticker Runnable on
the main `Handler` (`:95-101`). Both are on the platform main thread, competing
with Flutter's UI raster prep.

### 3.4 Where copies / hops actually happen

| Stage | Copy? | Thread |
|-------|-------|--------|
| Disk/`content://` → `CipherDataSource` | 1 read into buffer, decrypt **in place** (doc 03) | ExoPlayer loader thread |
| `CipherDataSource` → `MediaCodec` input | codec input buffer copy (unavoidable, compressed) | ExoPlayer playback thread |
| `MediaCodec` → `Surface` | **zero-copy** (graphics buffer) | codec/GPU |
| `Surface` → Flutter composite | zero-copy (OES/HardwareBuffer) | GPU raster |
| Event `Map` → Dart | small serialize + main-thread post | main thread |

The only *frame-sized* copy is the codec input buffer, which is fundamental to
`MediaCodec`. Everything downstream is GPU-shared memory.

---

## Limitations (today)

- **L1 — Position ticker never pauses.** The 250 ms ticker
  (`PlayerInstance.kt:95-101`) starts at first `STATE_READY` and only stops at
  `dispose()`. A paused, backgrounded, or PiP'd player still emits ~4
  `position` events/sec across the event channel, each with a main-thread post.
- **L2 — No back-buffer.** `setBackBuffer(0, false)` (`:116`) means every
  backward seek re-reads and re-decrypts from source; rewind is never instant.
- **L3 — Rotation offloaded to Dart on Impeller.** When
  `handlesCropAndRotation()` is false, correct orientation depends on Dart
  applying a `RotatedBox` (`:222-229`); a mismatch reproduces the historical
  rotation bug.
- **L4 — MediaInfoProbe double-decrypts.** Two full metadata passes each with a
  fresh adapter (`MediaInfoProbe.kt:52,90`); the file header region is decrypted
  twice per probe.
- **L5 — MediaSession does not survive process death.** No
  `MediaSessionService`/foreground notification (`:419-421` ponytail note), so
  aggressive OEM process-killing stops background audio.
- **L6 — `getMediaInfo` requires a registered adapter even to read plaintext-ish
  metadata; API < 23 is unsupported** (`MediaInfoProbe.kt:40-43`).

## Performance: how to make it insane

- **P1 — Gate the ticker on `isPlaying`** *(biggest win)*. Stop the ticker in
  `onIsPlayingChanged(false)` and restart on `true`
  (`PlayerInstance.kt:261-264`, `:95-101`). Eliminates ~4 events/sec × N idle
  players of platform-channel + main-thread traffic; measurable as reduced main
  thread jank when multiple players are alive. Keep one final `sendPosition()`
  on pause so the UI stays accurate.
- **P2 — Enable a bounded back-buffer** for scrub-heavy UX: `setBackBuffer(30_000,
  true)` (`:116`) makes short rewinds instant and avoids re-decrypt, at ~tens of
  MB RAM. Expose it through `player_options` like the other buffer knobs.
- **P3 — Prefer surface transform over Dart rotation.** Where the platform
  supports it, drive playback through a `SurfaceProducer` that
  `handlesCropAndRotation()` so correction is always `0` (`:225-231`) — removes
  the Dart `RotatedBox` recomposite for rotated content.
- **P4 — Single-pass probe.** Merge the `MediaExtractor` and
  `MediaMetadataRetriever` passes onto one shared `CipherMediaDataSource`
  instance (or cache the decrypted header) to halve probe decrypt work
  (`MediaInfoProbe.kt:52,90`).
- **P5 — Coalesce position + buffered into the existing size events** where
  possible, and batch at the display cadence rather than a fixed 250 ms wall
  clock, to align channel traffic with frames the user can actually see.

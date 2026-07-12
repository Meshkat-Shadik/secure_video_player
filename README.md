# secure_video_player

Encrypted-at-rest video playback for Flutter with **on-the-fly native decryption** —
plaintext never touches disk. Encrypt, decrypt, and play, all from Dart.

| | Android | iOS |
|---|---|---|
| Engine | Media3 1.10.1 (ExoPlayer) custom `DataSource` | AVPlayer + `AVAssetResourceLoaderDelegate` |
| AES-CTR / XOR-legacy ciphers | ✅ | ✅ |
| ClearKey DRM (CENC) | ✅ | ❌ `platformNotSupported` |
| Texture & PlatformView rendering | ✅ | ✅ |
| Tracks (audio/subtitle/quality) | ✅ (+ external SRT/VTT) | ✅ embedded only |
| SRT overlay (pure Dart, any platform) | ✅ | ✅ |
| PiP / background audio / capture block | ✅ | ✅ (PiP in PlatformView mode) |
| System media controls (notification / Now Playing) | ✅ | ✅ |
| Screen awake · sleep timer · progress triggers | ✅ | ✅ |

Designed for low-end devices: decryption uses one reused 64 KB buffer per player
(constant memory at any file size), and `BufferConfig.lowRam()` keeps Media3's
buffers small enough for 1 GB RAM phones.

---

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Encrypting & decrypting files](#encrypting--decrypting-files)
- [The controller](#the-controller)
- [The player widget](#the-player-widget)
- [Crypto schemes](#crypto-schemes)
- [Feature guide](#feature-guide)
  - [Subtitles: embedded, sideloaded, and pure-Dart SRT overlay](#subtitles)
  - [Picture-in-picture](#picture-in-picture)
  - [Background playback](#background-playback)
  - [System media controls (notification / Now Playing)](#system-media-controls)
  - [Keep screen awake](#keep-screen-awake)
  - [Sleep timer](#sleep-timer)
  - [Progress triggers](#progress-triggers)
  - [Screen-capture protection](#screen-capture-protection)
  - [Screen brightness](#screen-brightness)
  - [Media info probe](#media-info-probe)
  - [Tracks & track selection](#tracks--track-selection)
- [Platform setup](#platform-setup)
- [Error handling](#error-handling)
- [Example app](#example-app)
- [Architecture notes](#architecture-notes)

---

## Install

```yaml
dependencies:
  secure_video_player: 
    git: 'https://github.com/Meshkat-Shadik/secure_video_player.git'
```

```dart
import 'package:secure_video_player/secure_video_player.dart';
```

Minimum: Flutter 3.35 / Dart 3.6. Android `minSdk` 21, iOS 13. See
[Platform setup](#platform-setup) for the manifest / Info.plist entries each
feature needs.

---

## Quick start

```dart
// 1. Encrypt a downloaded file (streams in 1 MB chunks, any size).
final scheme = CryptoScheme.aesCtr(key: my16or32ByteKey, nonce: my8ByteNonce);
final op = await SecureVideoEncryptor.encrypt(plainPath, encryptedPath, scheme);
await op.done();                 // or listen to op.progress for a bar
File(plainPath).deleteSync();    // only ciphertext remains on disk

// 2. Play it. Decryption happens inside the native read loop.
final controller = SecureVideoController();
await controller.initialize(
  source: VideoSource.file(encryptedPath),
  scheme: scheme,
  options: const PlayerOptions(autoPlay: true),
);

// 3. Drop the widget anywhere. Ships Flutter controls + fullscreen.
SecureVideoPlayer(controller: controller);

// 4. Clean up.
controller.dispose();
```

Everything else — speed, seek, tracks, PiP, subtitles, timers — is on the
controller and covered below.

---

## Encrypting & decrypting files

`SecureVideoEncryptor` transforms whole files through the same native cipher used
for playback, on a background thread, in 1 MB chunks (constant memory).

```dart
// Encrypt, with a progress bar.
final op = await SecureVideoEncryptor.encrypt(plainPath, encPath, scheme);
await for (final p in op.progress) {
  print('${(p.fraction * 100).round()}%  (${p.bytesProcessed}/${p.totalBytes})');
}

// Or just wait for it.
await op.done();

// Decrypt back to a plaintext file (rarely needed — playback decrypts live).
final dec = await SecureVideoEncryptor.decrypt(encPath, outPath, scheme);
await dec.done();

// Cancel mid-flight — the partial output file is deleted natively.
await op.cancel();
```

`op.done()` throws a typed `SecureVideoException` on failure or cancel.

---

## The controller

`SecureVideoController` is a `ValueNotifier<SecureVideoValue>` — listen to it, or
use it with `ValueListenableBuilder`, to react to state.

```dart
final controller = SecureVideoController();

await controller.initialize(
  source: VideoSource.file(encryptedPath),   // .file / .asset / .url / .contentUri
  scheme: scheme,
  options: const PlayerOptions(
    autoPlay: true,
    looping: false,
    volume: 1.0,
    startPosition: Duration.zero,
    renderMode: RenderMode.texture,           // or RenderMode.platformView
    buffer: BufferConfig.lowRam(),            // 1 GB RAM devices
    keepScreenAwakeWhilePlaying: true,        // see Keep screen awake
    allowBackgroundPlayback: false,           // see Background playback
    mediaControls: MediaControlsOptions(...),  // see System media controls
  ),
);

// Transport.
await controller.play();
await controller.pause();
await controller.seekTo(const Duration(minutes: 5)); // O(1) — AES-CTR is seekable
await controller.setSpeed(1.5);
await controller.setLooping(true);
await controller.setVolume(0.4);
final now = await controller.position();   // fresh position (events are ~4/s)

controller.dispose();   // releases the native player; cancels timers/triggers
```

`SecureVideoValue` fields: `state` (`uninitialized`/`buffering`/`ready`/
`completed`/`error`), `position`, `buffered`, `duration`, `size`,
`rotationCorrection`, `isPlaying`, `speed`, `volume`, `looping`, `isPipActive`,
`error`, plus `aspectRatio` and `isInitialized`.

```dart
ValueListenableBuilder<SecureVideoValue>(
  valueListenable: controller,
  builder: (context, v, _) => Text('${v.position} / ${v.duration}'),
);
```

### Video sources

| Constructor | Meaning |
|---|---|
| `VideoSource.file(path)` | Local file (the encrypted file for non-`none` schemes) |
| `VideoSource.asset(key)` | Flutter asset (copied to a temp file natively) |
| `VideoSource.url(url)` | Network URL — only with `CryptoScheme.none` or `clearKey` |
| `VideoSource.contentUri(uri)` | Android `content://` MediaStore file, decrypted on the fly (no plaintext copy) |

---

## The player widget

`SecureVideoPlayer` (texture mode) ships controls with: seek bar + buffered
indicator, elapsed/total time, play/pause, speed menu, mute, track/subtitle
selection, PiP, fullscreen, **double-tap left/right seek** (`doubleTapSeek`,
default 5 s), **fit cycle** (fit/crop/stretch), **rotate button** (fullscreen),
and **next/previous** buttons when you pass `onNext`/`onPrevious`. In fullscreen,
vertical swipes on the **left half set brightness** and the **right half set
volume**, with a HUD.

```dart
final playerKey = GlobalKey<SecureVideoPlayerState>();   // needed for PiP, below

SecureVideoPlayer(
  key: playerKey,
  controller: controller,
  showControls: true,
  fit: BoxFit.contain,
  allowFullscreen: true,
  doubleTapSeek: const Duration(seconds: 10),
  onNext: () => _loadNext(),          // shows a next button
  onPrevious: () => _loadPrevious(),  // shows a previous button

  // Fullscreen orientation control:
  fullscreenOrientations: const [DeviceOrientation.landscapeLeft],
  // Under an app-wide orientation lock, restore YOUR orientations on exit —
  // otherwise leaving fullscreen unlocks all of them. null = restore all.
  restoreOrientationsAfterFullscreen: const [DeviceOrientation.portraitUp],
);
```

Rotation metadata is handled end-to-end: the platform reports display-oriented
sizes plus a `rotationCorrection`, and the widget rotates the raw texture, so
portrait recordings render upright in both texture and platformView modes.

**PlatformView mode** (`RenderMode.platformView`) embeds the native player view
with native controls. Pass `showControls: false` to avoid double controls.

---

## Crypto schemes

| Scheme | Use | Params |
|---|---|---|
| `CryptoScheme.none()` | plain files / URLs | — |
| `CryptoScheme.xorLegacy()` | Hulkenstein backward compat (skip 512 B, XOR 256 B with `0xAB`) | `skipOffset`, `corruptionSize`, `key` |
| `CryptoScheme.aesCtr(...)` | **recommended** — real encryption, O(1) seek | `key` (16/32 B), `nonce` (8 B) |
| `CryptoScheme.clearKey(...)` | CENC-packaged MP4/DASH, Android only | `keys` (base64url kid→k) |

```dart
// Recommended: AES-128/256 in CTR mode. Seekable, real confidentiality.
final scheme = CryptoScheme.aesCtr(
  key: Uint8List.fromList(my16or32Bytes),
  nonce: Uint8List.fromList(my8Bytes),   // MUST be unique per (key, file)
);
```

> **Security note.** AES-CTR gives confidentiality, not integrity — there is no
> MAC, so tampering is undetected. Never reuse a `(key, nonce)` pair across two
> files (classic two-time-pad break). `xorLegacy` is obfuscation only, for
> migrating existing Hulkenstein content.

The transform runs in the native read loop and must be position-addressable —
byte *N* decrypts without reading `0..N-1` (CTR keystreams and positional XOR
qualify; CBC does not). The **same** transform powers `SecureVideoEncryptor`;
keystream/XOR ciphers are involutions, so encrypt == decrypt.

---

## Feature guide

### Subtitles

Three independent paths — pick per source:

**1. Embedded tracks** (in the container). Enumerate and select:

```dart
final subs = await controller.getTracks('subtitle');
await controller.selectTrack('subtitle', subs.first.id);
await controller.selectTrack('subtitle', null);   // turn off
```

**2. Sideloaded SRT/VTT file** (Android). Adds an external file as a selectable
track through the native renderer:

```dart
await controller.addExternalSubtitle(
  '/path/to/subs.srt',
  mimeType: 'application/x-subrip',   // or 'text/vtt'
  language: 'en',
);
// It now appears in getTracks('subtitle'); select it as above.
```

**3. Pure-Dart SRT overlay** (any platform, **works with encrypted video and
texture mode**, where native cue rendering never reaches the screen). Parse an
SRT string/file, then stack `SrtSubtitleOverlay` over the player:

```dart
// Parse (both are pure Dart, O(n), forgiving of BOM/CRLF/tags/malformed blocks).
final cues = SrtSubtitles.fromString(srtText);
final cues = await SrtSubtitles.fromFile('/path/to/subs.srt');

Stack(
  children: [
    SecureVideoPlayer(controller: controller),
    SrtSubtitleOverlay(
      controller: controller,
      subtitles: cues,
      delay: const Duration(milliseconds: 0),  // +later / -earlier; live-adjustable
      style: const TextStyle(color: Colors.white, fontSize: 18),
      alignment: Alignment.bottomCenter,
    ),
  ],
);
```

The overlay interpolates between the controller's ~4/s position events with a
`Ticker`, keeping cues within a frame of the real position (≤50 ms), and only
rebuilds when the active cue changes. Change `delay` by rebuilding with a new
value (e.g. from a slider). `<i>/<b>/<u>` markup renders as styled spans;
`SubtitleCue.plainText` gives the tag-free string.

### Picture-in-picture

**Use the widget-level entry point.** Android shrinks the *whole activity* into
the PiP window, so `controller.enterPictureInPicture()` from an inline player
captures the surrounding scaffold/appbar. The widget hosts a bare fullscreen
video route first, enters PiP, and pops it again when PiP ends — restoring the
screen exactly as it was:

```dart
final playerKey = GlobalKey<SecureVideoPlayerState>();
SecureVideoPlayer(key: playerKey, controller: controller);

await playerKey.currentState!.enterPictureInPicture();
```

The built-in controls' PiP button already routes through this. On iOS the PiP
window floats independently, so the widget skips the host route. `value.isPipActive`
flips back to false when the user closes/expands the window; controls hide while
PiP is active. Android needs the [manifest opt-in](#platform-setup).

### Background playback

Keep decoding audio when the app is backgrounded. Enable via the option (applied
at create) or at runtime:

```dart
options: const PlayerOptions(allowBackgroundPlayback: true),
// or later:
await controller.setBackgroundPlayback(true);
```

Requires host-app setup — Android a foreground service, iOS `UIBackgroundModes:
audio`. See [Platform setup](#platform-setup). Pair with
[system media controls](#system-media-controls) for lock-screen transport.

### System media controls

Show a media notification (Android, via `MediaSessionService`) / Now Playing +
remote commands (iOS). Configure at create or update live:

```dart
options: PlayerOptions(
  mediaControls: const MediaControlsOptions(
    enabled: true,
    title: 'Big Buck Bunny',
    artist: 'Blender Foundation',
    artworkPath: '/path/to/cover.jpg',   // local file, optional
  ),
),

// Update metadata at runtime (e.g. on track change):
await controller.updateMediaControls(const MediaControlsOptions(
  enabled: true, title: 'Next episode', artist: 'Season 2',
));

// Tear down:
await controller.updateMediaControls(const MediaControlsOptions(enabled: false));
```

Android 13+ needs the `POST_NOTIFICATIONS` runtime permission (request it in your
app; the plugin does not). See [Platform setup](#platform-setup).

### Keep screen awake

On by default while playing. Ref-counted across controllers, so multiple players
never fight — the screen stays awake while any player wants it, sleeps once none
do.

```dart
// Option (default true): awake automatically while THIS player plays.
options: const PlayerOptions(keepScreenAwakeWhilePlaying: true),

// Manual override:
controller.setKeepScreenAwake(true);    // force awake regardless of play state
controller.setKeepScreenAwake(false);   // force allow sleep
controller.setKeepScreenAwake(null);    // back to automatic
```

Android toggles `FLAG_KEEP_SCREEN_ON`; iOS toggles `isIdleTimerDisabled`.

### Sleep timer

Pure-Dart, single timer, pauses at expiry.

```dart
controller.setSleepTimer(
  const Duration(minutes: 30),
  onFired: () => print('paused by sleep timer'),
);

final left = controller.sleepTimerRemaining;   // Duration? — null if none
controller.cancelSleepTimer();
```

Canceled automatically on `dispose`.

### Progress triggers

Fire a callback when playback crosses a point. O(1) per position event, seek-aware
(a seek is a jump, not a playthrough — intermediate triggers don't fire).

```dart
// Absolute position.
final h = controller.addProgressTrigger(
  ProgressTrigger.at(const Duration(seconds: 30), () => showSkipIntro()),
);

// Percent of duration (resolved once duration is known).
controller.addProgressTrigger(
  ProgressTrigger.percent(0.9, () => showUpNext()),
);

// Re-arm on backward crossing (seek back / loop) instead of once:
controller.addProgressTrigger(
  ProgressTrigger.at(const Duration(minutes: 1), pingAnalytics, once: false),
);

h.cancel();   // stop a trigger
```

Firing is forward-crossing (`prev < point <= now`). `once: false` re-arms
whenever playback moves back below the point.

### Screen-capture protection

Block screenshots / screen recording (Android `FLAG_SECURE`; iOS best-effort).

```dart
await setScreenCaptureProtection(true);
await setScreenCaptureProtection(false);
```

Top-level function (window-level, not per player). Remember to turn it off when
leaving the screen.

### Screen brightness

Window brightness, 0.0–1.0 (`-1` restores the system default). The fullscreen
controls use this for the left-edge swipe; call it directly if you build your own
controls.

```dart
final current = await getScreenBrightness();   // -1 = following system
await setScreenBrightness(0.8);
await setScreenBrightness(-1);                  // restore system default
```

iOS brightness is device-global and persists — capture and restore it yourself.

### Media info probe

Container + per-stream codec/profile/resolution/fps/bitrate/sampleRate/channels/
language, decrypted through the same cipher as playback.

```dart
final info = await getMediaInfo(encryptedPath, scheme: scheme);
print('${info.durationMs} ms, ${info.container}, ${info.streams.length} streams');
for (final s in info.streams) {
  print('${s.type}: ${s.codec} ${s.width}x${s.height} @ ${s.frameRate}fps');
}
```

### Tracks & track selection

```dart
final audio = await controller.getTracks('audio');
final subs  = await controller.getTracks('subtitle');
final video = await controller.getTracks('video');   // quality ladder (Android)

await controller.selectTrack('audio', audio[1].id);
await controller.selectTrack('subtitle', null);       // off (or auto for video)
```

`VideoTrack` exposes `id`, `type`, `selected`, `label`, `language`, `width`,
`height`, `bitrate`, and a `displayName` convenience getter.

---

## Platform setup

Only add what the features you use require.

### Android — `android/app/src/main/AndroidManifest.xml`

Picture-in-picture (activity opt-in — PiP silently fails without it):

```xml
<activity
    android:name=".MainActivity"
    android:supportsPictureInPicture="true"
    android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
    ...>
```

Background playback + media notification declare a foreground service (the plugin
ships the `MediaSessionService`; declare the permissions in your app):

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<!-- Android 13+ media notification: request POST_NOTIFICATIONS at runtime. -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

### iOS — `ios/Runner/Info.plist`

Background audio + media controls:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

iOS PiP requires `RenderMode.platformView` (needs an `AVPlayerLayer`); texture
mode uses a hidden layer workaround that some OS versions may reject.

---

## Error handling

Everything throws a typed `SecureVideoException` with a `SecureVideoErrorCode`:

| Code | Meaning |
|---|---|
| `invalidKey` | wrong/short key material |
| `fileNotFound` | source path/URI missing |
| `corruptStream` | undecodable bytes (wrong key, truncated, tampered) |
| `adapterNotRegistered` | unknown scheme type with no native cipher adapter |
| `drmError` | ClearKey / DRM failure |
| `platformNotSupported` | feature unavailable on this platform |
| `disposed` | controller used after dispose |
| `unknown` | anything else |

Playback errors surface on `controller.value.error` (state becomes `error`);
`initialize` and one-shot calls throw. Handle both:

```dart
try {
  await controller.initialize(source: ..., scheme: ...);
} on SecureVideoException catch (e) {
  if (e.code == SecureVideoErrorCode.invalidKey) { /* re-fetch key */ }
}

ValueListenableBuilder<SecureVideoValue>(
  valueListenable: controller,
  builder: (context, v, _) => v.state == SecureVideoState.error
      ? Text('Playback failed: ${v.error?.code.name}')
      : SecureVideoPlayer(controller: controller),
);
```

---

## Example app

`example/lib/main.dart` is the gallery shell: it wires the menu, preps sample
media, and routes to the actual feature screens. The real implementations live
in `example/lib/screens/*.dart`, with shared demo crypto in
`example/lib/demo_crypto.dart` and sample file preparation in
`example/lib/sample_media.dart`.

The gallery is grouped into **Feature demos** (progress triggers + sleep
timer, SRT overlay, media controls, screen awake,
PiP/background/secure), **Playback & crypto** (scheme matrix, encrypt→play,
tracks, texture vs platformView), and **Stress & edge cases** (error cases,
4-player grid, list recycling, seek hammer, buffer tuning). Every screen shows
a PASS/FAIL chip.

Key entry points:

- [example/lib/main.dart](example/lib/main.dart) - gallery navigation and sample prep
- [example/lib/demo_crypto.dart](example/lib/demo_crypto.dart) - demo cipher presets
- [example/lib/sample_media.dart](example/lib/sample_media.dart) - sample file generation

Gallery map:

| Demo | Implementation |
|---|---|
| Progress triggers + sleep timer | [example/lib/screens/progress_triggers_sleep_timer_screen.dart](example/lib/screens/progress_triggers_sleep_timer_screen.dart) |
| SRT subtitles + delay | [example/lib/screens/srt_subtitles_screen.dart](example/lib/screens/srt_subtitles_screen.dart) |
| Media controls | [example/lib/screens/media_controls_screen.dart](example/lib/screens/media_controls_screen.dart) |
| Screen awake | [example/lib/screens/screen_awake_screen.dart](example/lib/screens/screen_awake_screen.dart) |
| PiP / background / secure | [example/lib/screens/lifecycle_screen.dart](example/lib/screens/lifecycle_screen.dart) |
| Scheme matrix | [example/lib/screens/scheme_matrix_screen.dart](example/lib/screens/scheme_matrix_screen.dart) |
| Encrypt → play | [example/lib/screens/encrypt_play_screen.dart](example/lib/screens/encrypt_play_screen.dart) |
| Tracks & subtitles | [example/lib/screens/tracks_screen.dart](example/lib/screens/tracks_screen.dart) |
| Texture vs PlatformView | [example/lib/screens/render_toggle_screen.dart](example/lib/screens/render_toggle_screen.dart) |
| Error cases | [example/lib/screens/error_cases_screen.dart](example/lib/screens/error_cases_screen.dart) |
| 4-player grid | [example/lib/screens/multi_player_screen.dart](example/lib/screens/multi_player_screen.dart) |
| List recycling stress | [example/lib/screens/list_stress_screen.dart](example/lib/screens/list_stress_screen.dart) |
| Seek hammer + speed + loop | [example/lib/screens/seek_stress_screen.dart](example/lib/screens/seek_stress_screen.dart) |
| Buffer tuning (low RAM) | [example/lib/screens/buffer_screen.dart](example/lib/screens/buffer_screen.dart) |

```bash
cd example && flutter run
```

On-device integration tests live in `example/integration_test/`:

```bash
cd example && flutter test integration_test/ -d <device-id>
```

---

## Architecture notes

- **AES-CTR seek math:** keystream block *i* = `AES-ECB(key, nonce ‖ i)`; for
  file position *p*, start at block `p ~/ 16` and drop `p % 16` keystream bytes.
  Keystream generation is batched per read chunk (one JCE/CommonCrypto call →
  hardware AES).
- **Zero plaintext on disk:** the pixel plane never crosses the bridge — only a
  `textureId` does — and decrypt stays off the UI thread on both platforms.
- **Events:** one `EventChannel` per player (`secure_video_player/events_<id>`),
  buffered natively until Dart subscribes — no lost `initialized` races.
- **Control plane** is Pigeon-generated (`pigeons/messages.dart`); regenerate
  with `dart run pigeon --input pigeons/messages.dart`.
- Full design docs and diagrams live in `docs/architecture/`.

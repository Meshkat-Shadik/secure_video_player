# Feature Wave Architecture — binding contracts for worker agents

Architect: main session. Workers implement EXACTLY these contracts. Deviations require reporting back, not improvising.

## Ground truth (verified)

- Pigeon API already has: `enterPictureInPicture`, `setBackgroundPlayback`, `addExternalSubtitle`, `selectTrack`, `setSecureFlag`, brightness, `startCrypto`. Native impls exist on both platforms.
- Dart controller exposes NONE of those. Gap = Dart plumbing, not native.
- Android background playback = in-process `MediaSession` only (`PlayerInstance.kt:446`), no notification, no foreground service.
- iOS PiP requires `playerLayer` → platformView mode only today (`SecureVideoPlayerPlugin.swift:310-312`).
- `CreateRequest.schemeType` already supports "custom adapter name" → `CipherRegistry` extension point exists natively.
- Perf fix 4 (iOS CADisplayLink pause + NV12) NOT yet applied — folded into W4.

## Pigeon additions (done by architect, already generated — workers use, never edit)

```dart
class MediaControlsConfig {
  bool enabled;          // show system media controls (notification / now-playing)
  String? title;
  String? artist;
  String? artworkPath;   // local file path, optional
}
// HostApi additions:
void setKeepScreenAwake(bool enabled);                       // global window/app level
void configureMediaControls(int playerId, MediaControlsConfig config);
```

## Work packages

### W1 — Dart core (controller + options + triggers + sleep + wakelock plumbing)
Files: `lib/src/controller.dart`, `lib/src/player_options.dart`, NEW `lib/src/progress_triggers.dart`, `lib/secure_video_player.dart` (exports), `test/controller_test.dart` + new test files.

1. **Options**: add to `PlayerOptions`: `keepScreenAwakeWhilePlaying` (bool, default true), `mediaControls` (Dart-side `MediaControlsOptions {enabled, title, artist, artworkPath}`, default disabled), `allowBackgroundPlayback` (bool, default false).
2. **Wakelock**: controller listens to its own `isPlaying` transitions → calls `setKeepScreenAwake(true/false)` when option enabled. Ref-count across controllers via a static counter so two players don't fight (last-off wins). Manual override API: `controller.setKeepScreenAwake(bool?)` — null returns to automatic.
3. **Sleep timer**: pure Dart on controller. `setSleepTimer(Duration d, {VoidCallback? onFired})` → pauses at expiry; `cancelSleepTimer()`; `sleepTimerRemaining` getter; timer canceled on dispose. Single `Timer`, no polling.
4. **Progress triggers**: NEW `lib/src/progress_triggers.dart`. API:
   ```dart
   class ProgressTrigger { const ProgressTrigger.at(Duration position, cb, {bool once = true}); const ProgressTrigger.percent(double pct, cb, {bool once = true}); }
   TriggerHandle addProgressTrigger(ProgressTrigger t); // on controller
   ```
   Implementation contract (the "extreme optimised" requirement): triggers sorted by absolute time; percent resolved to absolute once duration known; a single cursor index; each position event compares ONLY against the next pending trigger (O(1) per tick, amortized); seek recomputes the cursor via binary search (O(log n)); no allocation on the tick path; forward-crossing fires (prev < t <= now); `once:false` re-arms when position moves back below the point. Fire callbacks via `scheduleMicrotask`-free direct call but guarded against reentrancy/dispose.
5. **Expose existing native APIs on controller**: `enterPictureInPicture()`, `setBackgroundPlayback(bool)` (auto-called from option at create), `addExternalSubtitle(path, mimeType, {language})`, `selectTrack`, `getTracks` if missing.
6. **Media controls plumbing**: at create (and on `updateMediaControls(...)` API), call pigeon `configureMediaControls`.
7. Tests for: trigger math (crossing, seek back/forward, percent resolution, once/re-arm), sleep timer, wakelock refcount (mock host api).

### W2 — Dart SRT subtitles (ZERO edits to controller.dart / player_options.dart — standalone)
Files: NEW `lib/src/subtitles/srt_parser.dart`, NEW `lib/src/subtitles/subtitle_overlay.dart`, `lib/secure_video_player.dart` (exports only), `lib/src/widgets/player_view.dart` and/or `controls.dart` integration, new tests.

1. **Parser**: strict-but-forgiving SRT → `List<SubtitleCue>{index,start,end,text}`; handles BOM, CRLF, multi-line text, basic `<i><b><u>` tags (strip or map to TextStyle), malformed-block skip. Pure Dart, O(n) parse, immutable result.
2. **Overlay widget**: `SrtSubtitleOverlay(controller: c, subtitles: cues, delay: Duration, style/position config)`. Cue lookup by binary search + cursor (same O(1) advance pattern as W1 triggers — independent implementation, do not import W1 files). Position source: controller.value position events (~4/s) + linear interpolation `pos + (now - lastEventAt) * speed` while playing, re-anchored on each event — target ≤50ms visual sync error.
3. **Sync**: `delay` shifts cue times (±). Runtime-adjustable via widget rebuild or a `ValueNotifier<Duration>`.
4. Loader helper: `SrtSubtitles.fromFile(path)`, `fromString(s)`. Note in docs: this path works with encrypted video (subs render in Flutter, independent of native pipeline) and in texture mode where native cue rendering never reaches the screen.
5. Tests: parser edge cases, cue lookup around seeks, delay math.

### W3 — Android native (wakelock + media notification + new pigeon impls)
Files: `SecureVideoPlayerPlugin.kt`, `PlayerInstance.kt`, NEW `PlaybackService.kt` (if service route), `android/src/main/AndroidManifest.xml`, `android/build.gradle.kts` only if a media3 artifact is missing.

1. **setKeepScreenAwake**: `activity.window.addFlags/clearFlags(FLAG_KEEP_SCREEN_ON)` on main thread; no-op with warning log when no activity.
2. **configureMediaControls**: media3 `MediaSessionService` (`PlaybackService.kt`) + `MediaSession` handoff so a foreground media notification with play/pause/seek appears; artwork from `artworkPath` if provided. Declare service + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permission in plugin manifest. `enabled=false` tears it down. Must interop with existing `setBackgroundPlayback` MediaSession (one MediaSession per player — reuse, don't duplicate). Android 13+ notification permission: document, don't request.
3. Keep `dispose()` releasing everything (service unbind, session release).
4. Compile gate: `cd example/android && ./gradlew :secure_video_player:compileDebugKotlin` (JAVA_HOME = Android Studio JBR).

### W4 — iOS native (perf fix 4 + wakelock + now-playing + texture-mode PiP + new pigeon impls)
Files: `ios/Classes/PlayerInstance.swift`, `SecureVideoPlayerPlugin.swift` minimal.

1. **Perf fix 4a**: pause `CADisplayLink` when not playing (rate/timeControlStatus observers), resume on play; keep last frame on screen; paused-seek drives one texture update.
2. **Perf fix 4b**: `AVPlayerItemVideoOutput` → NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) unless a real BGRA dependency is found — then report with evidence, don't force.
3. **setKeepScreenAwake**: `UIApplication.shared.isIdleTimerDisabled` on main thread.
4. **configureMediaControls**: `MPNowPlayingInfoCenter` (title/artist/artwork/elapsed/duration/rate updates) + `MPRemoteCommandCenter` (play/pause/seek). `enabled=false` clears + removes targets. Note: background audio needs host-app `UIBackgroundModes: audio` — document, don't fake.
5. **Texture-mode PiP**: attach a hidden/offscreen `AVPlayerLayer` on the same `AVPlayer` and build `AVPictureInPictureController` from it so `enterPictureInPicture()` works in texture mode too. If OS rejects (layer must be in hierarchy/visible), add it 1pt transparent to key window. If genuinely blocked after real attempts, report evidence — don't ship a fake.
6. Compile gate: `cd example/ios && pod install && xcodebuild -workspace Runner.xcworkspace -scheme Runner -sdk iphonesimulator build` (or closest achievable; report honestly).

### W5 — Dart-pluggable custom cipher (WAVE 2 — starts only after W3+W4 land)
Concept: `schemeType: 'dartProxy'`, `schemeParams: {channelId}`. Native `DartProxyCipherAdapter` registered in `CipherRegistry` forwards `(fileOffset, ciphertextChunk)` over a dedicated `BasicMessageChannel` (BinaryCodec) named `secure_video_player/dart_cipher_<channelId>`; Dart side runs user's `DartCipherDelegate.decrypt(Uint8List chunk, int fileOffset) → Uint8List`. Android read thread blocks on latch with timeout (platform thread never blocked → no deadlock); iOS resource loader is already async. Document perf tradeoff vs native schemes. Full contract issued when wave 2 starts.

## Verification gates (architect runs after each wave)
- `fvm flutter analyze` clean, `fvm flutter test` green.
- Android `compileDebugKotlin` green.
- iOS compile attempted; result recorded.
- Reviewer agent on full diff; findings fixed before user handoff.

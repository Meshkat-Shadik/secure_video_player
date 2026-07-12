## 0.4.0

Feature wave: six new capabilities + P0 performance fixes.

* **Screen awake**: `keepScreenAwakeWhilePlaying` option (default true) keeps
  the screen on while playing, ref-counted across players;
  `setKeepScreenAwake(bool?)` forces on/off or returns to automatic (null).
* **Sleep timer**: `setSleepTimer(duration, onFired:)`, `cancelSleepTimer()`,
  `sleepTimerRemaining` — pauses playback at expiry.
* **System media controls**: `MediaControlsOptions` / `updateMediaControls` —
  Android foreground media notification (`MediaSessionService`), iOS
  Now Playing + remote commands; `allowBackgroundPlayback` option.
* **Fullscreen-aware PiP**: `SecureVideoPlayerState.enterPictureInPicture()`
  (via `GlobalKey`) hosts a bare fullscreen video route before entering PiP on
  Android — the PiP window shows only the video, not the surrounding
  scaffold — and pops it automatically when PiP ends. iOS texture-mode PiP via
  a hidden `AVPlayerLayer`.
* **Progress triggers**: `addProgressTrigger(ProgressTrigger.at/.percent)` —
  O(1)-per-tick scheduler with seek-aware cursor, `once`/re-arm semantics.
* **SRT subtitles**: pure-Dart `parseSrt` / `SrtSubtitles` +
  `SrtSubtitleOverlay` with ticker interpolation (≤50 ms sync) and runtime
  `delay` — renders in Flutter, so it works with encrypted video and texture
  mode.
* **Dart-pluggable ciphers**: `CryptoScheme.dartProxy(channelId:)` +
  `DartCipher.register(channelId, delegate)` — implement decrypt/encrypt in
  pure Dart, no native code. Playback and file encrypt/decrypt both proxy
  through a binary channel (per-chunk IPC; native adapters stay the fast path).
* **Perf (P0)**: cached AES `Cipher` instance (was re-created per chunk),
  zero-copy read into ExoPlayer's buffer, position ticker gated on
  `isPlaying`, iOS NV12 output + paused `CADisplayLink`.
* **Fix**: Android `dartProxy` sent an empty channel message (`ByteBuffer.flip`
  before send — the messenger dispatches bytes `[0, position)`), so every read
  failed with "Dart cipher delegate returned an error or no data". Verified by
  an on-device integration test (encrypt roundtrip + real playback).
* **Fix**: sideloaded external subtitles (SRT/VTT) crashed playback under
  media3 1.10 ("Legacy decoding is disabled, can't handle text/vtt"). The
  player now enables legacy subtitle decoding on the text renderer.
* **Fix**: truncated / undecodable files now report `corruptStream` instead of
  `unknown` — `CipherDataSource` throws a typed position-out-of-range error and
  the error mapping covers decoder failures and reads past EOF.
* On-device integration tests added under `example/integration_test/`
  (dartProxy roundtrip, sideloaded VTT, error-case mapping, gallery smoke).

## 0.3.1

* **Rotation fix (regression)**: Android no longer falls back to
  `VideoSize.unappliedRotationDegrees` — it uses only the container's
  `Format.rotationDegrees`, exactly like the official `video_player` plugin.
  The fallback rotated some **landscape** streams 90° by mistake (they report a
  non-zero `unappliedRotationDegrees`). Portrait correction is unaffected.

## 0.3.0

* **`VideoSource.contentUri`** (Android): play an encrypted `content://`
  MediaStore file directly — decrypts on the fly through the ContentResolver
  fd, no plaintext copy on disk. Lets an app encrypt a gallery video **in
  place** (via `MediaStore.createWriteRequest` write consent, no
  All-Files-Access) and still play it. `CipherDataSource` now opens either a
  file path or a content URI.

## 0.2.0

Rotation, PiP, controls v2, media info.

* **Rotation fixed**: platforms now report display-oriented sizes plus a
  `rotationCorrection`; `SecureVideoPlayer` rotates the raw texture so
  portrait recordings render upright (texture + platformView, Android + iOS).
  Fullscreen auto-orientation now uses the corrected display aspect.
* **PiP**: `pipChanged` now also fires when the user closes/expands the PiP
  window (state polling); PiP aspect ratio clamped to Android's allowed
  range; controls hidden while PiP is active; README documents the required
  `android:supportsPictureInPicture="true"` manifest opt-in.
* **Controls v2**: `Material` wrapper (fixes unstyled yellow-underline text),
  double-tap left/right seek (`doubleTapSeek`), fullscreen swipe gestures —
  left half brightness / right half volume with HUD, fit cycle button
  (fit/crop/stretch), manual rotate button in fullscreen, `onNext`/`onPrevious`
  playlist buttons, `PlayerUiState` shared between inline and fullscreen.
* **New APIs**: `getMediaInfo(path, scheme:)` — container + per-stream
  codec/profile/resolution/fps/bitrate/sampleRate/channels/language, decrypted
  through the same cipher as playback; `setScreenBrightness` /
  `getScreenBrightness`.

## 0.0.1

* Initial release: encrypted-at-rest playback (Media3 / AVPlayer), AES-CTR /
  XOR-legacy / ClearKey / custom cipher registry, file encryptor, tracks,
  PiP, background audio, capture protection.

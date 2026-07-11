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

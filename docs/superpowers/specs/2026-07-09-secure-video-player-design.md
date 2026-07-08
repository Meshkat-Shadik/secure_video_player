# secure_video_player — Design Spec (2026-07-09)

Flutter plugin for encrypted-at-rest video playback with on-the-fly native decryption.
Android: Media3 1.10.1. iOS: AVPlayer + AVAssetResourceLoaderDelegate.
Origin: Hulkenstein `native-player` branch (XOR/ExoPlayer 2.19.1 app-embedded player) + "Encrypted Video Playback Architecture" research PDF.

## Goals

- Standalone plugin (not app code): encrypt, decrypt, and play encrypted local video.
- Files stay fully encrypted on disk at all times; decryption happens in the native read path in memory (no temp plaintext files).
- Runs on 1 GB RAM devices: constant-memory crypto (single reused 64 KB buffer per source), tuned Media3 LoadControl, per-instance lifecycle release.
- Caller-pluggable crypto: enum-style presets parameterized from Dart + native extension registry for custom ciphers.
- Multiple simultaneous player instances.
- Example app is a pass/fail edge-case gallery proving every feature.

## Non-goals

- Download manager (caller downloads; plugin encrypts after).
- Network streaming of encrypted content (v1 plays local files; plain URLs work through the `none` scheme where the OS player supports them).
- Hard DRM guarantees — XOR/AES-CTR protect at rest; a rooted device can dump memory.

## Crypto layer

Dart sealed class `CryptoScheme`, serialized as `{type, params}` over the channel:

| Scheme | Params | Notes |
|---|---|---|
| `none` | — | plain playback (also used for URL/asset tests) |
| `xorLegacy` | skipOffset=512, corruptionSize=256, key=0xAB | byte-compatible with Hulkenstein files |
| `aesCtr` | key (16/32 B), nonce (8 B) | keystream = AES-ECB(counter); position-addressable → O(1) seek |
| `clearKey` | keys: {kid→k} base64url | Media3 CENC DRM pipeline; **Android only**, iOS → `platformNotSupported` |
| `custom` | adapterName + free-form params | resolved via native `CipherRegistry` |

Native `CipherAdapter` interface (Kotlin + Swift, identical shape):

```
init(params)                                  // key material, offsets
transform(buffer, offset, length, filePosition)  // in-place, position-addressable
plaintextSize(cipherSize) -> size             // identity for all built-ins
```

- One generic `CipherDataSource` (Media3 `DataSource`) / `CipherResourceLoaderDelegate` (iOS) serves every adapter. New cipher = one native class + `CipherRegistry.register("name") { MyAdapter() }` in MainActivity/AppDelegate.
- Same adapter powers `SecureVideoEncryptor.encrypt/decrypt(inPath, outPath, scheme)`: native background thread, 1 MB chunks, progress events, cancel. AES-CTR encrypt == decrypt (XOR keystream), XOR is an involution, so one code path.
- AES-CTR seek math: counterBlock = nonce ‖ (position / 16), then discard (position % 16) keystream bytes.

## Player core

- `playerId → instance` map on both platforms; per-player `EventChannel` `secure_video_player/events_<id>`.
- Control plane: Pigeon-generated typed host API (`pigeons/messages.dart` → Dart/Kotlin/Swift).
- Android: ExoPlayer(Media3 1.10.1) + `ProgressiveMediaSource(CipherDataSource.Factory)`; ClearKey uses `MediaItem.DrmConfiguration(CLEARKEY_UUID)` with local keys JSON. LoadControl: minBuffer 15 s, maxBuffer 30 s, backBuffer 0 — low-RAM default, overridable via `BufferConfig`.
- iOS: `AVURLAsset` with custom URL scheme → resource loader delegate reads the encrypted file, transforms requested byte ranges through the adapter, answers `AVAssetResourceLoadingRequest`s.
- Rendering hybrid: `RenderMode.texture` (default; Android `SurfaceProducer`, iOS `AVPlayerItemVideoOutput` + `FlutterTexture`) or `RenderMode.platformView` (Android `PlayerView` with native controls, iOS `AVPlayerViewController`).
- Features: play/pause/seek, speed 0.25–3×, loop, volume/mute, audio-track + subtitle (embedded + sideloaded SRT/VTT) + video-quality selection, PiP, background audio (Android `MediaSessionService` + notification, iOS AVAudioSession), `FLAG_SECURE` toggle, position save/restore, buffering/state/size/error event stream.

## Dart API surface

```dart
final controller = SecureVideoController();
await controller.initialize(
  source: VideoSource.file(path),           // .file | .asset | .url
  scheme: CryptoScheme.aesCtr(key: k, nonce: n),
  options: PlayerOptions(renderMode: RenderMode.texture, buffer: BufferConfig.lowRam()),
);
SecureVideoPlayer(controller: controller);    // widget; ships SecureVideoControls overlay
controller.value / controller.events          // position, duration, buffered, state, size, tracks, errors
SecureVideoEncryptor.encrypt(input, output, scheme)  // Stream<EncryptProgress>
```

Errors: typed codes `invalidKey, fileNotFound, corruptStream, adapterNotRegistered, drmError, platformNotSupported, disposed` → `SecureVideoException`.

## Example app gallery

Each screen shows a visible PASS/FAIL check:
1. Scheme matrix: none / xorLegacy / aesCtr / clearKey / custom-adapter demo
2. Encrypt→play: bundle plain asset → encrypt with progress → play encrypted → source deleted
3. Error cases: wrong key, truncated file, missing file, unregistered adapter
4. 4-player grid + ListView recycling stress
5. Seek hammer + speed + loop
6. Tracks: audio/subtitles/quality menus
7. PiP, background audio, lifecycle (home/resume/rotate), FLAG_SECURE
8. Texture vs PlatformView toggle
9. Buffer knobs + memory readout (low-RAM mode)

## Testing

- Dart: scheme serialization, controller state machine over mocked channel.
- Native: adapter round-trip encrypt→decrypt byte-identical; transform-at-offset equals full-stream slice (seek correctness).
- Integration: example app screens.

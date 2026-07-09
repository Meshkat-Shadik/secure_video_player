# secure_video_player

Encrypted-at-rest video playback for Flutter with **on-the-fly native decryption** —
plaintext never touches disk. Encrypt, decrypt, and play, all from Dart.

| | Android | iOS |
|---|---|---|
| Engine | Media3 1.10.1 (ExoPlayer) custom `DataSource` | AVPlayer + `AVAssetResourceLoaderDelegate` |
| AES-CTR / XOR-legacy / custom ciphers | ✅ | ✅ |
| ClearKey DRM (CENC) | ✅ | ❌ `platformNotSupported` |
| Texture & PlatformView rendering | ✅ | ✅ |
| Tracks (audio/subtitle/quality) | ✅ (+ external SRT/VTT) | ✅ embedded only |
| PiP / background audio / capture block | ✅ | ✅ (PiP in PlatformView mode) |

Designed for low-end devices: decryption uses one reused 64 KB buffer per player
(constant memory at any file size), and `BufferConfig.lowRam()` keeps Media3's
buffers small enough for 1 GB RAM phones.

## Quick start

```dart
import 'package:secure_video_player/secure_video_player.dart';

// 1. Encrypt a downloaded file (streams in 1 MB chunks, any size).
final scheme = CryptoScheme.aesCtr(key: my16or32ByteKey, nonce: my8ByteNonce);
final op = await SecureVideoEncryptor.encrypt(plainPath, encryptedPath, scheme);
await for (final p in op.progress) { print('${(p.fraction * 100).round()}%'); }
File(plainPath).deleteSync(); // only ciphertext remains on disk

// 2. Play it. Decryption happens inside the native read loop.
final controller = SecureVideoController();
await controller.initialize(
  source: VideoSource.file(encryptedPath),
  scheme: scheme,
  options: const PlayerOptions(
    autoPlay: true,
    buffer: BufferConfig.lowRam(),          // 1 GB RAM devices
    renderMode: RenderMode.texture,          // or RenderMode.platformView
  ),
);

// 3. Widget. Ships Flutter controls with a fullscreen button.
SecureVideoPlayer(
  controller: controller,
  // Under an app-wide orientation lock? Set the orientations to restore on
  // fullscreen exit — otherwise leaving fullscreen unlocks all of them.
  // Default null = restore all (non-breaking).
  restoreOrientationsAfterFullscreen: const [DeviceOrientation.portraitUp],
);

// 4. Everything else.
controller.setSpeed(1.5);
controller.seekTo(const Duration(minutes: 5)); // O(1) — AES-CTR is seekable
final subs = await controller.getTracks('subtitle');
await controller.selectTrack('subtitle', subs.first.id);
await controller.enterPictureInPicture();
await controller.setBackgroundPlayback(true);
await setScreenCaptureProtection(true);      // FLAG_SECURE
controller.dispose();
```

## Built-in schemes

| Scheme | Use | Params |
|---|---|---|
| `CryptoScheme.none()` | plain files / URLs | — |
| `CryptoScheme.xorLegacy()` | Hulkenstein backward compat (skip 512 B, XOR 256 B with `0xAB`) | `skipOffset`, `corruptionSize`, `key` |
| `CryptoScheme.aesCtr(...)` | **recommended** — real encryption, O(1) seek | `key` (16/32 B), `nonce` (8 B) |
| `CryptoScheme.clearKey(...)` | CENC-packaged MP4/DASH, Android only | `keys` (base64url kid→k) |
| `CryptoScheme.custom(...)` | your own cipher (guide below) | `adapterName` + free-form params |

Errors are typed: `SecureVideoException` with `invalidKey`, `fileNotFound`,
`corruptStream`, `adapterNotRegistered`, `drmError`, `platformNotSupported`, `disposed`.

## Custom cipher guide

Video decryption runs in the native read loop (MB/s). A Dart callback per chunk
would stall playback on low-end devices, so custom ciphers are **native classes
registered by name** and referenced from Dart. Three steps:

### 1. Implement the adapter (one class per platform)

The contract (identical on both platforms):

- `init(params)` — receives the `params` map from Dart (key material, offsets).
- `transform(buffer, filePosition)` — decrypt bytes **in place**. Must be a pure
  function of `(bytes, filePosition)` — the player seeks anywhere, so byte *N*
  must decrypt without reading bytes `0..N-1` (position-addressable). Stream
  ciphers (CTR-style keystreams, positional XOR) qualify; CBC does not.
- The **same** transform is used by `SecureVideoEncryptor` — keystream/XOR
  ciphers are involutions, so encrypt == decrypt automatically.

Kotlin (`android/.../MainActivity.kt`):

```kotlin
class MyCipher : CipherAdapter {
    private lateinit var key: ByteArray
    override fun init(params: Map<String, Any?>) {
        key = (params["key"] as List<*>).map { (it as Number).toByte() }.toByteArray()
    }
    override fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long) {
        for (i in 0 until length) {
            val k = key[((filePosition + i) % key.size).toInt()]
            buffer[offset + i] = (buffer[offset + i].toInt() xor k.toInt()).toByte()
        }
    }
}
```

Swift (`ios/Runner/AppDelegate.swift`):

```swift
final class MyCipher: CipherAdapter {
  private var key: [UInt8] = []
  func initialize(params: [String: Any?]) throws {
    key = (params["key"] as! [Any]).map { UInt8(truncating: $0 as! NSNumber) }
  }
  func transform(_ buffer: inout Data, filePosition: Int64) {
    let n = Int64(key.count)
    buffer.withUnsafeMutableBytes { raw in
      let b = raw.bindMemory(to: UInt8.self)
      for i in 0..<b.count { b[i] ^= key[Int((filePosition + Int64(i)) % n)] }
    }
  }
}
```

### 2. Register it at app startup

```kotlin
// MainActivity.onCreate
CipherRegistry.register("myCipher") { MyCipher() }
```

```swift
// AppDelegate.didFinishLaunchingWithOptions
CipherRegistry.shared.register("myCipher") { MyCipher() }
```

### 3. Use it from Dart

```dart
const scheme = CryptoScheme.custom(
  adapterName: 'myCipher',
  params: {'key': [0x5A, 0xC3, 0x0F]},   // channel-serializable values only
);
await SecureVideoEncryptor.encrypt(inPath, outPath, scheme);
await controller.initialize(source: VideoSource.file(outPath), scheme: scheme);
```

Unregistered name → `SecureVideoException(adapterNotRegistered)` with the fix in
the message. The example app's `repeatingXor` adapter is a working reference.

## Example app

`example/` is an edge-case gallery — every screen shows a PASS/FAIL chip:
scheme matrix, encrypt→play pipeline, error cases (wrong key / truncated /
missing / unregistered), 4-player grid, list recycling stress, seek hammer,
tracks & subtitles, PiP/background/secure, Texture vs PlatformView, buffer
tuning. Run with `cd example && fvm flutter run`.

## Architecture notes

- **AES-CTR seek math:** keystream block *i* = `AES-ECB(key, nonce ‖ i)`;
  for file position *p*, start at block `p ~/ 16` and drop `p % 16` keystream
  bytes. Keystream generation is batched per read chunk (one JCE/CommonCrypto
  call → hardware AES).
- **Events:** one `EventChannel` per player (`secure_video_player/events_<id>`),
  buffered natively until Dart subscribes — no lost `initialized` races.
- Control plane is Pigeon-generated (`pigeons/messages.dart`); regenerate with
  `dart run pigeon --input pigeons/messages.dart`.
- Background playback keeps a `MediaSession` (Android) for lock-screen
  controls; add a foreground `MediaSessionService` if you need playback to
  survive aggressive process death.

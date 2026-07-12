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
final info = await getMediaInfo(path, scheme: scheme); // codecs/streams/fps
controller.dispose();
```

## Player widget features

`SecureVideoPlayer` (texture mode) ships controls with: seek bar + buffered
indicator, speed menu, track/subtitle selection, PiP, mute, fullscreen,
**double-tap left/right seek** (`doubleTapSeek`, default 5 s), **fit cycle**
(fit/crop/stretch), **rotate button** (fullscreen), and **next/previous**
buttons when you pass `onNext`/`onPrevious`. In fullscreen, vertical swipes on
the **left half set screen brightness** and the **right half set volume**,
with a HUD overlay. Fullscreen auto-picks portrait/landscape from the video's
display aspect (rotation metadata applied).

Rotation metadata is handled end-to-end: the platform reports display-oriented
sizes plus a `rotationCorrection`, and the widget rotates the raw texture —
portrait phone recordings render upright in both texture and platformView
modes.

### Picture-in-picture (Android)

PiP silently fails unless the **app's activity opts in** — add to your
`AndroidManifest.xml`:

```xml
<activity
    android:name=".MainActivity"
    android:supportsPictureInPicture="true"
    android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
    ...>
```

The plugin polls PiP state, so `value.isPipActive` also flips back to false
when the user closes/expands the PiP window; `SecureVideoPlayer` hides its
controls while PiP is active.

**Prefer the widget-level entry point.** Android shrinks the *whole activity*
into the PiP window, so calling `controller.enterPictureInPicture()` from an
inline player captures the surrounding scaffold/appbar too. The widget hosts a
bare fullscreen video route first, enters PiP, and pops the route again when
PiP ends — the screen is restored exactly as it was:

```dart
final playerKey = GlobalKey<SecureVideoPlayerState>();
SecureVideoPlayer(key: playerKey, controller: controller);

await playerKey.currentState!.enterPictureInPicture();
```

On iOS the PiP window floats independently of the app UI, so the widget skips
the host route and just enters PiP.

## Built-in schemes

| Scheme | Use | Params |
|---|---|---|
| `CryptoScheme.none()` | plain files / URLs | — |
| `CryptoScheme.xorLegacy()` | Hulkenstein backward compat (skip 512 B, XOR 256 B with `0xAB`) | `skipOffset`, `corruptionSize`, `key` |
| `CryptoScheme.aesCtr(...)` | **recommended** — real encryption, O(1) seek | `key` (16/32 B), `nonce` (8 B) |
| `CryptoScheme.clearKey(...)` | CENC-packaged MP4/DASH, Android only | `keys` (base64url kid→k) |
| `CryptoScheme.custom(...)` | your own **native** cipher (guide below) | `adapterName` + free-form params |
| `CryptoScheme.dartProxy(...)` | your own cipher in **pure Dart**, no native code (guide below) | `channelId` |

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

## Custom encryption in Dart

Don't want to touch Kotlin/Swift? Implement the cipher in pure Dart with
`CryptoScheme.dartProxy`. A built-in native adapter forwards every read chunk to
your `DartCipherDelegate` over a dedicated channel and returns the transformed
bytes. Same position-addressable rule as native adapters: `decrypt(chunk,
fileOffset)` must be a pure function of its arguments and return exactly
`chunk.length` bytes.

```dart
import 'dart:typed_data';
import 'package:secure_video_player/secure_video_player.dart';

/// Repeating-key XOR — an involution, so the same delegate encrypts and decrypts.
class XorDelegate extends DartCipherDelegate {
  XorDelegate(this.key);
  final List<int> key;

  Uint8List _xor(Uint8List chunk, int fileOffset) {
    final out = Uint8List(chunk.length);
    for (var i = 0; i < chunk.length; i++) {
      out[i] = chunk[i] ^ key[(fileOffset + i) % key.length];
    }
    return out;
  }

  @override
  Uint8List decrypt(Uint8List chunk, int fileOffset) => _xor(chunk, fileOffset);

  @override
  Uint8List encrypt(Uint8List chunk, int fileOffset) => _xor(chunk, fileOffset);
}

// 1. Register once, before playback (keep the handle to unregister later).
final registration = DartCipher.register('myXor', XorDelegate([0x5A, 0xC3, 0x0F]));

// 2. Reference it from a scheme with the SAME channelId.
const scheme = CryptoScheme.dartProxy(channelId: 'myXor');
await SecureVideoEncryptor.encrypt(inPath, outPath, scheme);
await controller.initialize(source: VideoSource.file(outPath), scheme: scheme);

// 3. When done (e.g. in dispose):
registration.dispose();
```

**Performance:** every read chunk makes a round trip to the Dart isolate
(~64 KB on Android, loader-request sizes on iOS). That is fine for moderate
bitrates, but native adapters (`CryptoScheme.custom` / `aesCtr`) remain the fast
path for 4K/high-bitrate content. Keep the delegate light — never do heavy
synchronous work in `decrypt`, or playback will stutter. `getMediaInfo` may probe
on the platform's main thread, where a Dart cipher can't run; it fails fast with
a clear error rather than deadlocking, so probe encrypted files with a native
scheme if you need metadata.

**Multi-engine:** `dartProxy` binds to the **most recently attached** Flutter
engine's messenger (it's registered in a process-global cipher registry). Setups
that run more than one engine concurrently (e.g. multiple `FlutterEngine`s or
add-to-app with several hosts) are **not supported today** — the last engine to
attach wins, and detaching it unregisters the adapter. Use a native
`CryptoScheme.custom` adapter in multi-engine apps.

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

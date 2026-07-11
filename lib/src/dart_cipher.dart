import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Channel-name prefix for Dart-implemented ciphers. The full name is
/// `secure_video_player/dart_cipher_<channelId>`, matched natively by
/// `DartProxyCipherAdapter`.
const String kDartCipherChannelPrefix = 'secure_video_player/dart_cipher_';

/// Direction byte in a request frame asking Dart to **encrypt** a plaintext
/// chunk (used by the file encryptor). Any other value means decrypt (0).
const int _directionEncrypt = 1;

/// A pure-Dart cipher. Implement this to decrypt (and optionally encrypt)
/// video bytes without writing any Kotlin/Swift.
///
/// The native player streams each ciphertext chunk to Dart over a dedicated
/// channel and blocks a background read thread until you return the transformed
/// bytes. Both methods MUST return exactly as many bytes as they received and
/// must be a pure function of `(chunk, fileOffset)` so the player can seek
/// anywhere without reading from byte 0.
///
/// Keep the work light: this runs once per read chunk on the platform's UI
/// isolate. Heavy synchronous crypto here will stutter playback — see
/// [CryptoScheme.dartProxy] docs for the perf tradeoff. Native `CipherAdapter`s
/// remain the fast path.
abstract class DartCipherDelegate {
  /// Returns the plaintext for [chunk], which was read at absolute byte
  /// [fileOffset] in the encrypted file. Must return `chunk.length` bytes.
  FutureOr<Uint8List> decrypt(Uint8List chunk, int fileOffset);

  /// Returns the ciphertext for a plaintext [chunk] at [fileOffset]. Only
  /// invoked by the file encryptor; defaults to unsupported.
  FutureOr<Uint8List> encrypt(Uint8List chunk, int fileOffset) =>
      throw UnsupportedError(
          'encrypt is not implemented for this DartCipherDelegate');
}

/// Handle returned by [DartCipher.register]. Call [dispose] to unregister the
/// delegate (e.g. in your widget/state `dispose`).
class DartCipherRegistration {
  DartCipherRegistration._(this._channel, this._channelId);

  final BasicMessageChannel<ByteData?> _channel;
  final String _channelId;
  bool _disposed = false;

  /// Unregisters the delegate. Idempotent. Frees [_channelId] for re-use and
  /// clears the handler only if this registration still owns the channel (a
  /// later re-register of the same id, after this one was disposed, owns it).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (DartCipher._activeChannelIds.remove(_channelId)) {
      _channel.setMessageHandler(null);
    }
  }
}

/// Entry point for wiring a [DartCipherDelegate] to a [CryptoScheme.dartProxy].
abstract final class DartCipher {
  /// Channel ids with a live registration. Guards against two delegates
  /// silently sharing one channel (the second would steal it, and disposing
  /// the first would clear the second's handler).
  static final Set<String> _activeChannelIds = <String>{};

  /// Registers [delegate] under [channelId] and starts listening on
  /// `secure_video_player/dart_cipher_<channelId>`. Use the same [channelId]
  /// in [CryptoScheme.dartProxy]. Call [DartCipherRegistration.dispose] to stop.
  ///
  /// Throws [StateError] if [channelId] already has a live registration;
  /// dispose the existing one first, or use a distinct id.
  static DartCipherRegistration register(
    String channelId,
    DartCipherDelegate delegate,
  ) {
    if (!_activeChannelIds.add(channelId)) {
      throw StateError(
        'A DartCipher is already registered for channelId "$channelId". '
        'Dispose the existing registration before registering again, '
        'or use a different channelId.',
      );
    }
    final channel = BasicMessageChannel<ByteData?>(
      '$kDartCipherChannelPrefix$channelId',
      const BinaryCodec(),
    );
    channel.setMessageHandler(
      (ByteData? message) => _handle(message, delegate),
    );
    return DartCipherRegistration._(channel, channelId);
  }

  /// Parses a request frame, dispatches to the delegate and returns the
  /// transformed bytes. Returns `null` on any error — the native side treats a
  /// null/short reply as a read error rather than corrupting playback. Never
  /// throws across the channel.
  static Future<ByteData?> _handle(
    ByteData? message,
    DartCipherDelegate delegate,
  ) async {
    if (message == null || message.lengthInBytes < 9) return null;
    try {
      final direction = message.getUint8(0);
      final fileOffset = message.getInt64(1, Endian.big);
      final chunk = message.buffer.asUint8List(
        message.offsetInBytes + 9,
        message.lengthInBytes - 9,
      );
      final Uint8List result = direction == _directionEncrypt
          ? await delegate.encrypt(chunk, fileOffset)
          : await delegate.decrypt(chunk, fileOffset);
      if (result.length != chunk.length) {
        // Length mismatch would desync the stream; surface as a read error.
        return null;
      }
      return ByteData.sublistView(result);
    } catch (e, s) {
      debugPrint('DartCipher delegate error at frame: $e\n$s');
      return null;
    }
  }
}

import 'dart:async';

import 'package:flutter/services.dart';

import 'crypto_scheme.dart';
import 'errors.dart';
import 'messages.g.dart';

/// Progress of an encrypt/decrypt file transform.
class CryptoProgress {
  const CryptoProgress({
    required this.bytesProcessed,
    required this.totalBytes,
    required this.done,
  });

  final int bytesProcessed;
  final int totalBytes;
  final bool done;

  double get fraction => totalBytes == 0 ? 0 : bytesProcessed / totalBytes;
}

/// A running file transform. Listen to [progress]; call [cancel] to abort
/// (the partial output file is deleted natively).
class CryptoOperation {
  CryptoOperation._(this.id, this.progress);

  final String id;
  final Stream<CryptoProgress> progress;

  Future<void> cancel() => SecureVideoHostApi().cancelCrypto(id);

  /// Completes when the transform finishes (or throws on failure/cancel).
  Future<void> done() => progress.drain<void>();
}

/// Encrypts/decrypts whole files through the native `CipherAdapter` for the
/// given scheme. Runs on a native background thread in 1 MB chunks —
/// constant memory, any file size.
class SecureVideoEncryptor {
  SecureVideoEncryptor._();

  static const EventChannel _events =
      EventChannel('secure_video_player/crypto_events');
  static Stream<dynamic>? _broadcast;

  static Future<CryptoOperation> encrypt(
          String inputPath, String outputPath, CryptoScheme scheme) =>
      _start(inputPath, outputPath, scheme, encrypt: true);

  static Future<CryptoOperation> decrypt(
          String inputPath, String outputPath, CryptoScheme scheme) =>
      _start(inputPath, outputPath, scheme, encrypt: false);

  static Future<CryptoOperation> _start(
      String inputPath, String outputPath, CryptoScheme scheme,
      {required bool encrypt}) async {
    final String id;
    try {
      id = await SecureVideoHostApi().startCrypto(
          inputPath, outputPath, scheme.type, scheme.params, encrypt);
    } on PlatformException catch (e) {
      throw SecureVideoException.fromPlatform(e);
    }

    _broadcast ??= _events.receiveBroadcastStream().asBroadcastStream();
    final progress = _broadcast!
        .where((e) => e is Map && e['operationId'] == id)
        .map((e) {
          final m = (e as Map).cast<String, Object?>();
          final error = m['error'] as String?;
          if (error != null) {
            throw SecureVideoException(
                SecureVideoErrorCode.fromWire(m['errorCode'] as String?),
                error);
          }
          return CryptoProgress(
            bytesProcessed: (m['bytesProcessed'] as num?)?.toInt() ?? 0,
            totalBytes: (m['totalBytes'] as num?)?.toInt() ?? 0,
            done: m['done'] == true,
          );
        })
        .takeWhileInclusive((p) => !p.done);

    return CryptoOperation._(id, progress);
  }
}

extension<T> on Stream<T> {
  /// Like takeWhile but also emits the first non-matching element.
  Stream<T> takeWhileInclusive(bool Function(T) test) async* {
    await for (final e in this) {
      yield e;
      if (!test(e)) break;
    }
  }
}

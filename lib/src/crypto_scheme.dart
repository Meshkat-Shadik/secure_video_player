import 'dart:typed_data';

/// How a video file is encrypted at rest.
///
/// Every scheme serializes to `(type, params)` and is resolved natively by
/// the `CipherRegistry`. Built-ins: [NoneScheme], [XorLegacyScheme],
/// [AesCtrScheme], [ClearKeyScheme]. Custom ciphers implement a native
/// `CipherAdapter`, register it under a name at app startup, and are
/// referenced from Dart with [CryptoScheme.custom].
sealed class CryptoScheme {
  const CryptoScheme();

  const factory CryptoScheme.none() = NoneScheme;

  const factory CryptoScheme.xorLegacy({
    int skipOffset,
    int corruptionSize,
    int key,
  }) = XorLegacyScheme;

  const factory CryptoScheme.aesCtr({
    required Uint8List key,
    required Uint8List nonce,
  }) = AesCtrScheme;

  const factory CryptoScheme.clearKey({
    required Map<String, String> keys,
  }) = ClearKeyScheme;

  const factory CryptoScheme.custom({
    required String adapterName,
    Map<String, Object?> params,
  }) = CustomScheme;

  /// Wire identifier understood by the native side.
  String get type;

  /// Wire parameters passed to `CipherAdapter.init`.
  Map<String, Object?> get params;
}

/// Plain, unencrypted playback.
class NoneScheme extends CryptoScheme {
  const NoneScheme();

  @override
  String get type => 'none';

  @override
  Map<String, Object?> get params => const {};
}

/// Hulkenstein-compatible "corruption" scheme: skip [skipOffset] bytes,
/// XOR the next [corruptionSize] bytes with [key], leave the rest plain.
///
/// Not real security — kept for backward compatibility with existing files.
class XorLegacyScheme extends CryptoScheme {
  const XorLegacyScheme({
    this.skipOffset = 512,
    this.corruptionSize = 256,
    this.key = 0xAB,
  })  : assert(skipOffset >= 0),
        assert(corruptionSize > 0),
        assert(key >= 0 && key <= 0xFF);

  final int skipOffset;
  final int corruptionSize;
  final int key;

  @override
  String get type => 'xorLegacy';

  @override
  Map<String, Object?> get params => {
        'skipOffset': skipOffset,
        'corruptionSize': corruptionSize,
        'key': key,
      };
}

/// AES-CTR full-file stream cipher. Position-addressable, so seeking is O(1)
/// and encrypt/decrypt are the same operation.
class AesCtrScheme extends CryptoScheme {
  const AesCtrScheme({required this.key, required this.nonce});

  /// 16 (AES-128) or 32 (AES-256) bytes.
  final Uint8List key;

  /// 8-byte nonce; the remaining 8 counter bytes track the block index.
  final Uint8List nonce;

  @override
  String get type => 'aesCtr';

  @override
  Map<String, Object?> get params => {'key': key, 'nonce': nonce};
}

/// Media3 ClearKey DRM (CENC-packaged content). Android only — iOS throws
/// [SecureVideoErrorCode.platformNotSupported].
class ClearKeyScheme extends CryptoScheme {
  const ClearKeyScheme({required this.keys});

  /// base64url keyId -> base64url key.
  final Map<String, String> keys;

  @override
  String get type => 'clearKey';

  @override
  Map<String, Object?> get params => {'keys': keys};
}

/// A cipher registered natively via `CipherRegistry.register(adapterName)`.
class CustomScheme extends CryptoScheme {
  const CustomScheme({required this.adapterName, this.params = const {}});

  final String adapterName;

  @override
  final Map<String, Object?> params;

  @override
  String get type => adapterName;
}

import 'dart:typed_data';

import 'package:secure_video_player/secure_video_player.dart';

/// Fixed demo key material. Real apps derive/fetch these per user or per
/// file — never hardcode production keys.
class DemoCrypto {
  DemoCrypto._();

  static final Uint8List aesKey = Uint8List.fromList(List.generate(
      16, (i) => (i * 7 + 13) & 0xFF)); // 16 bytes -> AES-128

  static final Uint8List aesNonce =
      Uint8List.fromList(List.generate(8, (i) => (i * 31 + 5) & 0xFF));

  static final Uint8List wrongKey =
      Uint8List.fromList(List.generate(16, (i) => 0xEE));

  static CryptoScheme get aesCtr =>
      CryptoScheme.aesCtr(key: aesKey, nonce: aesNonce);

  static CryptoScheme get aesCtrWrongKey =>
      CryptoScheme.aesCtr(key: wrongKey, nonce: aesNonce);

  static const CryptoScheme xorLegacy = CryptoScheme.xorLegacy();

  /// Registered natively in MainActivity.kt / AppDelegate.swift — see the
  /// custom-cipher guide in the plugin README.
  static const CryptoScheme customRepeatingXor = CryptoScheme.custom(
    adapterName: 'repeatingXor',
    params: {
      'key': [0x5A, 0xC3, 0x0F, 0x99, 0x42]
    },
  );
}

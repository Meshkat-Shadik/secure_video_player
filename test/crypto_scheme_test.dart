import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';

void main() {
  group('CryptoScheme wire format', () {
    test('none', () {
      const scheme = CryptoScheme.none();
      expect(scheme.type, 'none');
      expect(scheme.params, isEmpty);
    });

    test('xorLegacy defaults match Hulkenstein constants', () {
      const scheme = CryptoScheme.xorLegacy();
      expect(scheme.type, 'xorLegacy');
      expect(scheme.params,
          {'skipOffset': 512, 'corruptionSize': 256, 'key': 0xAB});
    });

    test('xorLegacy custom params serialize', () {
      const scheme =
          CryptoScheme.xorLegacy(skipOffset: 0, corruptionSize: 1024, key: 1);
      expect(scheme.params,
          {'skipOffset': 0, 'corruptionSize': 1024, 'key': 1});
    });

    test('aesCtr carries key and nonce bytes', () {
      final key = Uint8List(16);
      final nonce = Uint8List(8);
      final scheme = CryptoScheme.aesCtr(key: key, nonce: nonce);
      expect(scheme.type, 'aesCtr');
      expect(scheme.params['key'], same(key));
      expect(scheme.params['nonce'], same(nonce));
    });

    test('clearKey carries kid->k map', () {
      const scheme = CryptoScheme.clearKey(keys: {'kid1': 'k1'});
      expect(scheme.type, 'clearKey');
      expect(scheme.params, {
        'keys': {'kid1': 'k1'}
      });
    });

    test('custom type is the adapter name', () {
      const scheme = CryptoScheme.custom(
          adapterName: 'repeatingXor', params: {'key': [1, 2, 3]});
      expect(scheme.type, 'repeatingXor');
      expect(scheme.params, {'key': [1, 2, 3]});
    });
  });

  group('SecureVideoErrorCode', () {
    test('maps wire codes', () {
      expect(SecureVideoErrorCode.fromWire('fileNotFound'),
          SecureVideoErrorCode.fileNotFound);
      expect(SecureVideoErrorCode.fromWire('adapterNotRegistered'),
          SecureVideoErrorCode.adapterNotRegistered);
      expect(SecureVideoErrorCode.fromWire('somethingRandom'),
          SecureVideoErrorCode.unknown);
      expect(
          SecureVideoErrorCode.fromWire(null), SecureVideoErrorCode.unknown);
    });
  });
}

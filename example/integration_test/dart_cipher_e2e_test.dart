import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart' as p;
import 'package:secure_video_player/secure_video_player.dart';

/// End-to-end proof that the dartProxy scheme works against the real native
/// pipeline: encrypt through FileCryptor (encrypt direction over the channel),
/// byte-compare a decrypt roundtrip, then play the ciphertext back through the
/// player (decrypt direction on the ExoPlayer/AVPlayer reader thread).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final key = Uint8List.fromList([0x5A, 0xC3, 0x0F, 0x99, 0x42]);

  testWidgets('dartProxy: encrypt roundtrip + real playback reaches ready',
      (tester) async {
    final dir = await p.getTemporaryDirectory();
    final plain = '${dir.path}/e2e_plain.mp4';
    final enc = '${dir.path}/e2e_dartproxy.enc';
    final dec = '${dir.path}/e2e_roundtrip.mp4';
    for (final f in [enc, dec]) {
      if (File(f).existsSync()) File(f).deleteSync();
    }
    final bytes = await rootBundle.load('assets/sample.mp4');
    File(plain).writeAsBytesSync(bytes.buffer.asUint8List());

    const channelId = 'e2e_xor';
    final reg = DartCipher.register(channelId, _XorDelegate(key));
    const scheme = CryptoScheme.dartProxy(channelId: channelId);

    try {
      // 1. Encrypt direction: native FileCryptor -> Dart delegate.
      final encOp = await SecureVideoEncryptor.encrypt(plain, enc, scheme);
      await encOp.done();
      expect(File(enc).existsSync(), isTrue);
      expect(File(enc).lengthSync(), File(plain).lengthSync());
      // Ciphertext must differ from plaintext (XOR actually applied).
      final head = File(enc).openSync().readSync(64);
      final plainHead = File(plain).openSync().readSync(64);
      expect(head, isNot(equals(plainHead)));

      // 2. Decrypt direction via file crypto: roundtrip must equal original.
      final decOp = await SecureVideoEncryptor.decrypt(enc, dec, scheme);
      await decOp.done();
      expect(File(dec).readAsBytesSync(), File(plain).readAsBytesSync());

      // 3. Decrypt direction via playback: reader thread -> Dart delegate.
      final controller = SecureVideoController();
      try {
        await controller.initialize(
          source: VideoSource.file(enc),
          scheme: scheme,
          options: const PlayerOptions(autoPlay: true),
        );
        expect(controller.value.state, SecureVideoState.ready);
        expect(controller.value.duration, greaterThan(Duration.zero));

        // Position must actually advance (frames decoded from proxied bytes).
        final before = controller.value.position;
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 3)));
        expect(controller.value.error, isNull);
        expect(controller.value.position, greaterThan(before));
      } finally {
        await controller.dispose();
      }
    } finally {
      reg.dispose();
    }
  });
}

class _XorDelegate extends DartCipherDelegate {
  _XorDelegate(this.key);
  final Uint8List key;

  Uint8List _xor(Uint8List chunk, int fileOffset) {
    final out = Uint8List(chunk.length);
    for (var i = 0; i < chunk.length; i++) {
      out[i] = chunk[i] ^ key[(fileOffset + i) % key.length];
    }
    return out;
  }

  @override
  Uint8List decrypt(Uint8List chunk, int fileOffset) =>
      _xor(chunk, fileOffset);

  @override
  Uint8List encrypt(Uint8List chunk, int fileOffset) =>
      _xor(chunk, fileOffset);
}

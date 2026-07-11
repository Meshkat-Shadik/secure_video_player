import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart' as p;
import 'package:secure_video_player/secure_video_player.dart';

import 'demo_crypto.dart';

/// Prepares every sample file the gallery screens need, once per install:
/// the plain video, encrypted variants of it (made with the plugin's own
/// encryptor — dogfooding the encrypt side), a truncated file, and an
/// external subtitle.
class SampleMedia {
  SampleMedia._();

  static late final String plainPath;
  static late final String xorPath;
  static late final String aesPath;
  static late final String customPath;
  static late final String truncatedPath;
  static late final String externalVttPath;

  static Future<void> prepare() async {
    final dir = await p.getApplicationDocumentsDirectory();
    final root = Directory('${dir.path}/svp_samples');
    root.createSync(recursive: true);

    plainPath = '${root.path}/plain.mp4';
    xorPath = '${root.path}/xor.enc';
    aesPath = '${root.path}/aes.enc';
    customPath = '${root.path}/custom.enc';
    truncatedPath = '${root.path}/truncated.enc';
    externalVttPath = '${root.path}/subs_external.vtt';

    if (!File(plainPath).existsSync()) {
      final bytes = await rootBundle.load('assets/sample.mp4');
      File(plainPath).writeAsBytesSync(bytes.buffer.asUint8List());
    }
    if (!File(externalVttPath).existsSync()) {
      final vtt = await rootBundle.loadString('assets/subs_external.vtt');
      File(externalVttPath).writeAsStringSync(vtt);
    }

    await _encryptIfMissing(xorPath, DemoCrypto.xorLegacy);
    await _encryptIfMissing(aesPath, DemoCrypto.aesCtr);
    await _encryptIfMissing(customPath, DemoCrypto.customRepeatingXor);

    if (!File(truncatedPath).existsSync()) {
      final full = File(aesPath).readAsBytesSync();
      // Keep only the first quarter — valid header, missing tail.
      File(truncatedPath).writeAsBytesSync(full.sublist(0, full.length ~/ 4));
    }
  }

  static Future<void> _encryptIfMissing(String out, CryptoScheme scheme) async {
    if (File(out).existsSync()) return;
    final op = await SecureVideoEncryptor.encrypt(plainPath, out, scheme);
    await op.done();
  }
}

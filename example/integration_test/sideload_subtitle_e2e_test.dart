import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart' as p;
import 'package:secure_video_player/secure_video_player.dart';

import 'package:secure_video_player_example/demo_crypto.dart';
import 'package:secure_video_player_example/sample_media.dart';

/// Reproduces the "Legacy decoding is disabled, can't handle text/vtt" crash:
/// sideload an external VTT onto an encrypted video and assert the player
/// keeps playing (no error event) with a new subtitle track selectable.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sideloaded VTT does not crash playback and adds a sub track',
      (tester) async {
    await SampleMedia.prepare();

    // Write a tiny VTT next to the samples.
    final dir = await p.getApplicationDocumentsDirectory();
    final vttPath = '${dir.path}/svp_samples/e2e_sideload.vtt';
    File(vttPath).writeAsStringSync('WEBVTT\n\n'
        '00:00:01.000 --> 00:00:04.000\nHello from a sideloaded VTT\n\n'
        '00:00:05.000 --> 00:00:08.000\nSecond cue\n');

    final controller = SecureVideoController();
    try {
      await controller.initialize(
        source: VideoSource.file(SampleMedia.aesPath),
        scheme: DemoCrypto.aesCtr,
        options: const PlayerOptions(autoPlay: true, looping: true),
      );
      expect(controller.value.state, SecureVideoState.ready);

      final before = await controller.getTracks('subtitle');

      await controller.addExternalSubtitle(vttPath,
          mimeType: 'text/vtt', language: 'en');

      // Give the source rebuild + re-prepare time to settle and play on.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 3)));

      // The crash surfaced as an error event; the fix keeps it null.
      expect(controller.value.error, isNull,
          reason: 'sideloaded VTT should not error the player');
      expect(controller.value.state, isNot(SecureVideoState.error));

      final after = await controller.getTracks('subtitle');
      expect(after.length, greaterThan(before.length),
          reason: 'the sideloaded VTT should appear as a subtitle track');

      // Select it and confirm playback still advances.
      await controller.selectTrack('subtitle', after.last.id);
      final pos = controller.value.position;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
      expect(controller.value.error, isNull);
      expect(controller.value.position, greaterThan(pos));
    } finally {
      await controller.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

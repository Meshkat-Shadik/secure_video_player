import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secure_video_player/secure_video_player.dart';

import 'package:secure_video_player_example/demo_crypto.dart';
import 'package:secure_video_player_example/sample_media.dart';

/// Each failure mode must surface as the expected typed error within a
/// reasonable time — never hang, never silently play.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<SecureVideoErrorCode?> outcome(
    WidgetTester tester,
    String path,
    CryptoScheme scheme,
  ) async {
    final c = SecureVideoController();
    try {
      await c.initialize(
        source: VideoSource.file(path),
        scheme: scheme,
        options: const PlayerOptions(autoPlay: true),
      );
    } on SecureVideoException catch (e) {
      return e.code;
    } catch (_) {/* fall through to poll value.error */}

    // Some errors arrive on the event stream after initialize resolves
    // (e.g. a truncated mdat errors only when the decoder reaches EOF).
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      if (c.value.error != null) {
        final code = c.value.error!.code;
        await c.dispose();
        return code;
      }
    }
    final state = c.value.state;
    await c.dispose();
    // No error at all → report the terminal state so the test message is useful.
    throw TestFailure('no error within 20s; ended in state $state');
  }

  testWidgets('error cases surface typed errors', (tester) async {
    await SampleMedia.prepare();

    expect(
      await outcome(tester, SampleMedia.aesPath, DemoCrypto.aesCtrWrongKey),
      SecureVideoErrorCode.corruptStream,
      reason: 'wrong AES key',
    );
    expect(
      await outcome(tester, SampleMedia.truncatedPath, DemoCrypto.aesCtr),
      SecureVideoErrorCode.corruptStream,
      reason: 'truncated file',
    );
    expect(
      await outcome(tester, '/nonexistent/video.enc', DemoCrypto.aesCtr),
      SecureVideoErrorCode.fileNotFound,
      reason: 'missing file',
    );
    expect(
      await outcome(tester, SampleMedia.aesPath,
          const CryptoScheme.custom(adapterName: 'noSuchCipher')),
      SecureVideoErrorCode.adapterNotRegistered,
      reason: 'unregistered adapter',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}

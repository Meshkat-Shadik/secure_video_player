import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:secure_video_player_example/main.dart' as app;

/// Opens every gallery screen, lets it run briefly, and asserts nothing
/// rendered a FAIL chip and no exception escaped. Real device/emulator only.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const demoTitles = [
    'Progress triggers + sleep timer',
    'SRT subtitles + delay',
    'Media controls',
    'Custom Dart cipher',
    'Screen awake',
    'PiP / background / secure',
    'Scheme matrix',
    'Encrypt → play',
    'Tracks & subtitles',
    'Texture vs PlatformView',
    'Error cases',
    '4-player grid',
    'List recycling stress',
    'Seek hammer + speed + loop',
    'Buffer tuning (low RAM)',
  ];

  testWidgets('every gallery screen opens and runs without FAIL',
      (tester) async {
    app.main();

    // Sample prep encrypts several files on first run — wait for the list.
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text(demoTitles.first).evaluate().isNotEmpty) break;
    }
    expect(find.text(demoTitles.first), findsOneWidget,
        reason: 'gallery did not finish sample preparation');

    for (final title in demoTitles) {
      final item = find.text(title);
      await tester.scrollUntilVisible(item, 150,
          scrollable: find.byType(Scrollable).first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(item, warnIfMissed: false);

      // Let the screen initialize and play. Some chips pass through transient
      // states (e.g. the truncated file reaches READY before the decoder hits
      // EOF and flips to PASS·corruptStream) — poll until FAIL clears instead
      // of snapshotting a moment mid-flight.
      var settled = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (i >= 6 && find.textContaining('FAIL').evaluate().isEmpty) {
          settled = true;
          break;
        }
      }
      expect(settled, isTrue,
          reason: '"$title" still rendered a FAIL chip after 20s');

      await tester.pageBack();
      await tester.pump(const Duration(seconds: 1));
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

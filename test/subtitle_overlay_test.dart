import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';

import 'controller_test.dart' show FakeHostApi;

/// Controller stub: playback state pushed directly, no platform channels.
class _FakeController extends SecureVideoController {
  _FakeController() : super(api: FakeHostApi()) {
    value = value.copyWith(state: SecureVideoState.ready);
  }

  void emit({Duration? position, bool? isPlaying, double? speed}) {
    value = value.copyWith(
      position: position,
      isPlaying: isPlaying,
      speed: speed,
    );
  }
}

/// Text.rich has no `data`; match on the flattened span text instead.
Finder subtitle(String s) => find.byWidgetPredicate(
    (w) => w is Text && (w.textSpan?.toPlainText() ?? w.data) == s);

void main() {
  final cues = parseSrt('1\n00:00:01,000 --> 00:00:02,000\nAlpha\n\n'
      '2\n00:00:03,000 --> 00:00:04,000\nBravo\n');

  Future<void> pump(WidgetTester tester, SrtSubtitleOverlay overlay) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: overlay)));

  testWidgets('shows the cue active at the current position (paused seeks)',
      (tester) async {
    final c = _FakeController();
    await pump(tester, SrtSubtitleOverlay(controller: c, subtitles: cues));

    c.emit(position: const Duration(milliseconds: 1500));
    await tester.pump();
    expect(subtitle('Alpha'), findsOneWidget);

    // seek into the gap → nothing shown
    c.emit(position: const Duration(milliseconds: 2500));
    await tester.pump();
    expect(subtitle('Alpha'), findsNothing);

    // seek forward
    c.emit(position: const Duration(milliseconds: 3500));
    await tester.pump();
    expect(subtitle('Bravo'), findsOneWidget);

    // seek back
    c.emit(position: const Duration(milliseconds: 1500));
    await tester.pump();
    expect(subtitle('Alpha'), findsOneWidget);
  });

  testWidgets('delay shifts cue timing', (tester) async {
    final c = _FakeController();
    await pump(
        tester,
        SrtSubtitleOverlay(
          controller: c,
          subtitles: cues,
          delay: const Duration(seconds: 1),
        ));

    // With a +1s delay, Alpha (1-2s) now plays at 2-3s.
    c.emit(position: const Duration(milliseconds: 1500));
    await tester.pump();
    expect(subtitle('Alpha'), findsNothing);

    c.emit(position: const Duration(milliseconds: 2500));
    await tester.pump();
    expect(subtitle('Alpha'), findsOneWidget);
  });

  testWidgets('interpolates position between events while playing',
      (tester) async {
    final c = _FakeController()..emit(position: Duration.zero, isPlaying: true);
    await pump(tester, SrtSubtitleOverlay(controller: c, subtitles: cues));

    // No new position event, but the ticker advances wall time to 1.5s.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(subtitle('Alpha'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2000)); // -> ~3.5s
    await tester.pump();
    expect(subtitle('Bravo'), findsOneWidget);
  });

  testWidgets('speed change mid-play does not jump cues backward',
      (tester) async {
    // Raw position 950ms (just before Alpha 1000-2000ms), playing.
    final c = _FakeController()
      ..emit(position: const Duration(milliseconds: 950), isPlaying: true);
    await pump(tester, SrtSubtitleOverlay(controller: c, subtitles: cues));

    // Ticker interpolates ~100ms forward → 1050ms, inside Alpha.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(subtitle('Alpha'), findsOneWidget);

    // Speed change while playing carries the stale 950ms position. Must
    // re-anchor to the interpolated ~1050ms, not snap back to 950ms (which
    // would drop Alpha, being before the cue start).
    c.emit(speed: 2.0);
    await tester.pump();
    expect(subtitle('Alpha'), findsOneWidget);
  });

  testWidgets('renders inline italic markup as a styled span', (tester) async {
    final italic = parseSrt(
        '1\n00:00:01,000 --> 00:00:02,000\n<i>slanted</i>\n');
    final c = _FakeController()..emit(position: const Duration(milliseconds: 1500));
    await pump(tester, SrtSubtitleOverlay(controller: c, subtitles: italic));
    await tester.pump();

    final text = tester.widget<Text>(subtitle('slanted'));
    final span = text.textSpan! as TextSpan;
    expect(span.children!.first.style!.fontStyle, FontStyle.italic);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';

import 'controller_test.dart' show FakeHostApi;

/// Controller stub: state set directly, no platform channels.
class _FakeController extends SecureVideoController {
  _FakeController({
    required double width,
    required double height,
    required int rotationCorrection,
  }) : super(api: FakeHostApi()) {
    value = value.copyWith(
      state: SecureVideoState.ready,
      size: Size(width, height),
      rotationCorrection: rotationCorrection,
    );
  }

  @override
  int? get playerId => 7;

  @override
  int? get textureId => 42;
}

/// Regression tests for the SVP-rotation bug (shipped twice):
/// the native side reports DISPLAY dimensions (Media3 already swaps w/h for
/// 90/270 rotations) plus the raw-frame rotation correction; the Dart side
/// must lay the texture out at raw (stored) dimensions inside a RotatedBox
/// so the final box is display-sized with upright content.
void main() {
  Future<void> pump(WidgetTester tester, SecureVideoController c) =>
      tester.pumpWidget(MaterialApp(
          home: SecureVideoPlayer(controller: c, showControls: false)));

  testWidgets('rotated video: raw-sized texture inside a RotatedBox',
      (tester) async {
    // Display 1920x1080, frames stored 1080x1920 rotated 90°.
    final c = _FakeController(width: 1920, height: 1080, rotationCorrection: 90);
    await pump(tester, c);

    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    final box = tester.widget<SizedBox>(find.descendant(
        of: find.byType(RotatedBox), matching: find.byType(SizedBox)));
    expect(box.width, 1080); // raw (stored) dims, NOT display dims
    expect(box.height, 1920);
  });

  testWidgets('unrotated video: display-sized texture, no RotatedBox',
      (tester) async {
    final c = _FakeController(width: 1280, height: 720, rotationCorrection: 0);
    await pump(tester, c);

    expect(find.byType(RotatedBox), findsNothing);
    final box = tester.widget<SizedBox>(find.ancestor(
        of: find.byType(Texture), matching: find.byType(SizedBox)));
    expect(box.width, 1280);
    expect(box.height, 720);
  });

  testWidgets('swapping controllers re-targets the rendered texture',
      (tester) async {
    // Playlist next/prev: PlayerScreen replaces the controller in place.
    final a = _FakeController(width: 1280, height: 720, rotationCorrection: 0);
    await pump(tester, a);
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
    expect(find.byType(RotatedBox), findsNothing);

    final b = _FakeController(width: 1920, height: 1080, rotationCorrection: 90);
    await pump(tester, b);
    await tester.pump();
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
  });
}

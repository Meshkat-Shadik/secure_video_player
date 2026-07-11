import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/src/progress_triggers.dart';

void main() {
  late ProgressTriggerScheduler s;

  setUp(() => s = ProgressTriggerScheduler());

  test('fires once on forward crossing (prev < t <= now)', () {
    var count = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => count++));
    s.onPosition(500);
    expect(count, 0);
    s.onPosition(1500);
    expect(count, 1);
    s.onPosition(2500);
    expect(count, 1); // once:true — no re-fire
  });

  test('fires when position lands exactly on the point', () {
    var count = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => count++));
    s.onPosition(1000);
    expect(count, 1);
  });

  test('once:false re-arms after seeking back below the point', () {
    var count = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => count++,
        once: false));
    s.onPosition(1500);
    expect(count, 1);
    s.onSeek(0);
    s.onPosition(1500);
    expect(count, 2);
  });

  test('once:true does not re-fire after seeking back', () {
    var count = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => count++));
    s.onPosition(1500);
    s.onSeek(0);
    s.onPosition(1500);
    expect(count, 1);
  });

  test('backward jump via onPosition (loop) re-arms once:false', () {
    var count = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => count++,
        once: false));
    s.onPosition(1500);
    s.onPosition(0); // loop restart
    s.onPosition(1500);
    expect(count, 2);
  });

  test('forward seek does not fire intermediate triggers', () {
    var passed = 0;
    var later = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => passed++));
    s.add(ProgressTrigger.at(const Duration(seconds: 3), () => later++));
    s.onSeek(2000); // jump past the 1s trigger
    s.onPosition(2500);
    expect(passed, 0); // skipped by the seek
    s.onPosition(3100);
    expect(later, 1); // still fires normally
  });

  test('percent resolves to absolute time once duration is known', () {
    var count = 0;
    s.add(ProgressTrigger.percent(0.5, () => count++));
    // No duration yet: nothing to fire against.
    s.onPosition(6000);
    expect(count, 0);
    s.onSeek(0); // reset cursor for a clean playthrough
    s.setDuration(10000); // 0.5 -> 5000ms
    s.onPosition(4000);
    expect(count, 0);
    s.onPosition(6000);
    expect(count, 1);
  });

  test('multiple triggers crossed in one tick all fire in order', () {
    final order = <int>[];
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => order.add(1)));
    s.add(ProgressTrigger.at(const Duration(seconds: 2), () => order.add(2)));
    s.onPosition(2500);
    expect(order, [1, 2]);
  });

  test('cancelled trigger does not fire', () {
    var count = 0;
    final h = s.add(ProgressTrigger.at(const Duration(seconds: 1), () => count++));
    h.cancel();
    s.onPosition(1500);
    expect(count, 0);
  });

  test('dispose makes onPosition a no-op', () {
    var count = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () => count++));
    s.dispose();
    s.onPosition(1500); // must not throw or fire
    expect(count, 0);
  });

  test('callback may seek and add a trigger reentrantly', () {
    var first = 0;
    var added = 0;
    s.add(ProgressTrigger.at(const Duration(seconds: 1), () {
      first++;
      s.onSeek(0); // reentrant seek
      s.add(ProgressTrigger.at(const Duration(seconds: 2), () => added++));
    }));
    s.onPosition(1500);
    expect(first, 1);
    // Deferred structural changes applied after firing; new trigger is live.
    s.onPosition(2500);
    expect(added, 1);
  });
}

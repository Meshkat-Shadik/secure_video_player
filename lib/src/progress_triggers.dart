import 'package:flutter/foundation.dart';

/// A callback that fires when playback crosses a point in the timeline.
///
/// Create with [ProgressTrigger.at] for an absolute position or
/// [ProgressTrigger.percent] for a fraction of the (later-known) duration.
/// Register on a controller with `addProgressTrigger`, which returns a
/// [TriggerHandle] you can [TriggerHandle.cancel].
///
/// Firing is forward-crossing: the callback runs the moment playback moves
/// past the point (`prev < point <= now`). With `once: false` the trigger
/// re-arms whenever playback moves back below the point (seek back / loop).
class ProgressTrigger {
  const ProgressTrigger._({
    this.position,
    this.percent,
    required this.callback,
    required this.once,
  });

  /// Fires when playback reaches [position].
  const ProgressTrigger.at(
    Duration position,
    VoidCallback callback, {
    bool once = true,
  }) : this._(position: position, callback: callback, once: once);

  /// Fires when playback reaches [percent] (0.0–1.0) of the total duration.
  /// Resolved to an absolute position once the duration is known.
  const ProgressTrigger.percent(
    double percent,
    VoidCallback callback, {
    bool once = true,
  }) : this._(percent: percent, callback: callback, once: once);

  /// Absolute point for `.at` triggers; null for `.percent`.
  final Duration? position;

  /// Fraction (0.0–1.0) for `.percent` triggers; null for `.at`.
  final double? percent;

  final VoidCallback callback;

  /// Fire once and never again (default), vs. re-arm on backward crossing.
  final bool once;
}

/// Cancels a registered [ProgressTrigger]. Idempotent.
class TriggerHandle {
  TriggerHandle._(this._scheduler, this._trigger);

  final ProgressTriggerScheduler _scheduler;
  final _ScheduledTrigger _trigger;

  void cancel() => _scheduler._cancel(_trigger);
}

class _ScheduledTrigger {
  _ScheduledTrigger(this.callback, this.once, this.position, this.percent);

  final VoidCallback callback;
  final bool once;
  final Duration? position;
  final double? percent;

  /// Resolved absolute time in ms.
  int timeMs = 0;
  bool fired = false;
  bool cancelled = false;
}

/// Sorted absolute-time trigger list with a single cursor.
///
/// Performance contract:
/// - position events are O(1) amortized — each tick only compares against the
///   next pending trigger and never allocates;
/// - seeks recompute the cursor in O(log n) via binary search;
/// - percent triggers are resolved to absolute time once the duration is known;
/// - `once: false` re-arms when the cursor moves back below the point;
/// - callbacks run synchronously, guarded against dispose and reentrancy.
class ProgressTriggerScheduler {
  /// Authoritative set in registration order (includes unresolved percents).
  final List<_ScheduledTrigger> _all = <_ScheduledTrigger>[];

  /// Resolved, non-cancelled triggers sorted ascending by [timeMs].
  List<_ScheduledTrigger> _active = const <_ScheduledTrigger>[];

  int _cursor = 0;
  int _lastPosMs = 0;
  int _durationMs = 0;
  bool _firing = false;
  bool _dirty = false;
  bool _disposed = false;

  TriggerHandle add(ProgressTrigger t) {
    final st = _ScheduledTrigger(t.callback, t.once, t.position, t.percent);
    _all.add(st);
    _markDirtyOrRebuild();
    return TriggerHandle._(this, st);
  }

  void _cancel(_ScheduledTrigger st) {
    if (st.cancelled) return;
    st.cancelled = true;
    _markDirtyOrRebuild();
  }

  /// Called when the total duration becomes known (or changes). Resolves any
  /// pending percent triggers to absolute time.
  void setDuration(int durationMs) {
    if (durationMs == _durationMs) return;
    _durationMs = durationMs;
    _markDirtyOrRebuild();
  }

  /// Normal monotonic position update from a player event. Fires forward
  /// crossings (`prev < t <= now`); a backward jump (loop / native seek back)
  /// silently re-arms via cursor recompute.
  void onPosition(int nowMs) {
    if (_disposed || _firing) return;
    if (nowMs < _lastPosMs) {
      _lastPosMs = nowMs;
      _cursor = _upperBound(nowMs);
      return;
    }
    _lastPosMs = nowMs;
    _firing = true;
    try {
      final list = _active;
      var i = _cursor;
      while (i < list.length && list[i].timeMs <= nowMs) {
        final st = list[i];
        // Cursor invariant guarantees list[i].timeMs > previous position, so
        // (prev < t <= now) holds — only the upper bound needs checking.
        if (!st.cancelled && !st.fired) {
          if (st.once) st.fired = true;
          st.callback();
          if (_disposed) return;
        }
        i++;
      }
      _cursor = i;
    } finally {
      _firing = false;
      if (_dirty) {
        _dirty = false;
        _rebuild();
      }
    }
  }

  /// Explicit seek: reposition the cursor without firing intermediate
  /// triggers (a seek is a jump, not a playthrough).
  void onSeek(int targetMs) {
    if (_disposed) return;
    _lastPosMs = targetMs;
    if (_firing) {
      _dirty = true;
      return;
    }
    _cursor = _upperBound(targetMs);
  }

  void dispose() {
    _disposed = true;
    _all.clear();
    _active = const <_ScheduledTrigger>[];
  }

  void _markDirtyOrRebuild() {
    if (_firing) {
      _dirty = true;
    } else {
      _rebuild();
    }
  }

  void _rebuild() {
    final next = <_ScheduledTrigger>[];
    for (final st in _all) {
      if (st.cancelled) continue;
      if (st.position != null) {
        st.timeMs = st.position!.inMilliseconds;
      } else if (_durationMs > 0) {
        st.timeMs = (st.percent!.clamp(0.0, 1.0) * _durationMs).round();
      } else {
        continue; // percent trigger, duration not known yet
      }
      next.add(st);
    }
    next.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    _active = next;
    _cursor = _upperBound(_lastPosMs);
  }

  /// First index in [_active] whose timeMs is strictly greater than [pos].
  int _upperBound(int pos) {
    var lo = 0;
    var hi = _active.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_active[mid].timeMs <= pos) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

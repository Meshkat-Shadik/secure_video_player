import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../controller.dart';
import 'srt_parser.dart';

/// Renders SRT subtitles over a video. Stack it above a [SecureVideoPlayer] —
/// it reads only the controller's public value, so it needs no native cue
/// support and works with encrypted / texture-mode playback.
///
/// Sync: on every controller position event it re-anchors (position, speed,
/// playing); a [Ticker] then interpolates `anchor + elapsed × speed` per frame
/// while playing, keeping the visible cue within a frame of the real position.
/// Only the text region rebuilds, and only when the active cue changes.
class SrtSubtitleOverlay extends StatefulWidget {
  const SrtSubtitleOverlay({
    super.key,
    required this.controller,
    required this.subtitles,
    this.delay = Duration.zero,
    this.style,
    this.padding = const EdgeInsets.fromLTRB(24, 0, 24, 48),
    this.alignment = Alignment.bottomCenter,
    this.textAlign = TextAlign.center,
    this.background = const Color(0x99000000),
  });

  final SecureVideoController controller;
  final List<SubtitleCue> subtitles;

  /// Shifts cue times: positive delays subtitles, negative advances them.
  /// Adjust at runtime by rebuilding with a new value.
  final Duration delay;

  final TextStyle? style;
  final EdgeInsets padding;
  final Alignment alignment;
  final TextAlign textAlign;

  /// Backing behind the text for legibility; transparent to disable.
  final Color background;

  @override
  State<SrtSubtitleOverlay> createState() => _SrtSubtitleOverlayState();
}

class _SrtSubtitleOverlayState extends State<SrtSubtitleOverlay>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<SubtitleCue?> _current = ValueNotifier(null);
  late final Ticker _ticker;
  late SubtitleCueLookup _lookup = SubtitleCueLookup(widget.subtitles);

  int _anchorPosUs = 0;
  int _anchorElapsedUs = 0;
  int _lastElapsedUs = 0;
  int _lastRawPosUs = 0;
  double _speed = 1.0;
  bool _playing = false;
  int _delayUs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _delayUs = widget.delay.inMicroseconds;
    widget.controller.addListener(_reanchor);
    _reanchor();
  }

  @override
  void didUpdateWidget(SrtSubtitleOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_reanchor);
      widget.controller.addListener(_reanchor);
    }
    if (!identical(old.subtitles, widget.subtitles)) {
      _lookup = SubtitleCueLookup(widget.subtitles);
    }
    _delayUs = widget.delay.inMicroseconds;
    _reanchor();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reanchor);
    _ticker.dispose();
    _current.dispose();
    super.dispose();
  }

  /// Re-align interpolation with the latest controller state.
  void _reanchor() {
    final v = widget.controller.value;
    final rawPosUs = v.position.inMicroseconds;
    final wasPlaying = _playing;

    // Interpolated position under the CURRENT anchor/speed, before we change
    // them. A speed change while playing carries the stale last position event;
    // re-anchoring to it jumps cues backward up to ~250ms. Instead, when still
    // playing with no fresh position, anchor to where we've interpolated to.
    final interpolatedUs = wasPlaying
        ? _anchorPosUs + ((_lastElapsedUs - _anchorElapsedUs) * _speed).round()
        : _anchorPosUs;

    _speed = v.speed > 0 ? v.speed : 1.0;
    if (wasPlaying && v.isPlaying && rawPosUs == _lastRawPosUs) {
      _anchorPosUs = interpolatedUs;
    } else {
      _anchorPosUs = rawPosUs;
    }
    _anchorElapsedUs = _lastElapsedUs;
    _lastRawPosUs = rawPosUs;

    if (v.isPlaying != _playing) {
      _playing = v.isPlaying;
      if (_playing) {
        _ticker.start(); // resets ticker elapsed to zero
        _anchorElapsedUs = _lastElapsedUs = 0;
      } else {
        _ticker.stop();
      }
    }
    _update(_lastElapsedUs);
  }

  void _onTick(Duration elapsed) {
    _lastElapsedUs = elapsed.inMicroseconds;
    _update(_lastElapsedUs);
  }

  void _update(int elapsedUs) {
    // ponytail: int-microsecond math, no Duration allocation on the hot path.
    final tUs = _playing
        ? _anchorPosUs + ((elapsedUs - _anchorElapsedUs) * _speed).round()
        : _anchorPosUs;
    final cue = _lookup.atMicros(tUs - _delayUs);
    if (!identical(cue, _current.value)) _current.value = cue;
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? _defaultStyle;
    return IgnorePointer(
      child: Padding(
        padding: widget.padding,
        child: Align(
          alignment: widget.alignment,
          child: ValueListenableBuilder<SubtitleCue?>(
            valueListenable: _current,
            builder: (context, cue, _) {
              if (cue == null || cue.text.isEmpty) {
                return const SizedBox.shrink();
              }
              final text = Text.rich(
                _renderCue(cue.text, base),
                textAlign: widget.textAlign,
              );
              if (widget.background.a == 0) return text;
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.background,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  child: text,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static const _defaultStyle = TextStyle(
    color: Colors.white,
    fontSize: 18,
    fontWeight: FontWeight.w500,
    shadows: [Shadow(blurRadius: 4, color: Colors.black, offset: Offset(0, 1))],
  );
}

final _tagRe = RegExp(r'<(/?)([a-zA-Z]+)[^>]*>');

/// Renders `<i>/<b>/<u>` (nesting-aware) and strips any other tags.
TextSpan _renderCue(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  var italic = 0, bold = 0, underline = 0;
  var last = 0;

  void flush(int end) {
    if (end <= last) return;
    spans.add(TextSpan(
      text: text.substring(last, end),
      style: base.copyWith(
        fontStyle: italic > 0 ? FontStyle.italic : null,
        fontWeight: bold > 0 ? FontWeight.bold : null,
        decoration: underline > 0 ? TextDecoration.underline : null,
      ),
    ));
  }

  for (final m in _tagRe.allMatches(text)) {
    flush(m.start);
    final close = m.group(1) == '/';
    switch (m.group(2)!.toLowerCase()) {
      case 'i':
        italic += close ? -1 : 1;
      case 'b':
        bold += close ? -1 : 1;
      case 'u':
        underline += close ? -1 : 1;
      // unknown tags are stripped
    }
    if (italic < 0) italic = 0;
    if (bold < 0) bold = 0;
    if (underline < 0) underline = 0;
    last = m.end;
  }
  flush(text.length);
  return TextSpan(style: base, children: spans);
}

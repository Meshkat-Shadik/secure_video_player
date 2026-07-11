import 'dart:async';

import 'package:flutter/material.dart';

import '../controller.dart';
import 'player_view.dart';

/// Flutter-drawn playback controls: play/pause, seek bar with buffered
/// indicator, elapsed/total time, speed menu, mute, track selection, PiP,
/// fit/rotate, next/previous, double-tap seek, and (fullscreen) edge swipe
/// gestures — left half brightness, right half volume.
class SecureVideoControls extends StatefulWidget {
  const SecureVideoControls({
    super.key,
    required this.controller,
    this.ui,
    this.autoHide = const Duration(seconds: 3),
    this.isFullscreen = false,
    this.doubleTapSeek = const Duration(seconds: 5),
    this.onNext,
    this.onPrevious,
    this.onToggleFullscreen,
  });

  final SecureVideoController controller;

  /// Fit + manual rotation state; buttons hidden when null.
  final PlayerUiState? ui;
  final Duration autoHide;

  /// True when rendered inside the fullscreen route (button shows exit icon,
  /// swipe gestures active).
  final bool isFullscreen;

  /// Seek step for double-tap left/right. Zero disables the gesture.
  final Duration doubleTapSeek;

  /// Non-null shows the next/previous buttons.
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;

  /// Null hides the fullscreen button.
  final VoidCallback? onToggleFullscreen;

  @override
  State<SecureVideoControls> createState() => _SecureVideoControlsState();
}

class _SecureVideoControlsState extends State<SecureVideoControls> {
  bool _visible = true;
  Timer? _hideTimer;
  double? _dragValue;

  // Transient gesture feedback (double-tap seek, brightness/volume swipe).
  IconData? _hudIcon;
  String? _hudText;
  double? _hudFraction;
  Timer? _hudTimer;

  // Vertical swipe bookkeeping.
  bool? _dragIsBrightness;
  double _dragStartValue = 0;
  double _dragAccum = 0;

  // Brightness the fullscreen session started with (may be -1 = following
  // system), captured the first time a swipe changes brightness so it can be
  // restored on fullscreen exit / dispose — iOS UIScreen brightness is
  // device-global and would otherwise persist.
  double? _brightnessBeforeSwipe;

  SecureVideoController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    // Restore brightness the swipe changed (fullscreen exit disposes this
    // widget). Fire-and-forget: dispose can't await.
    if (_brightnessBeforeSwipe != null) {
      setScreenBrightness(_brightnessBeforeSwipe!);
      _brightnessBeforeSwipe = null;
    }
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.autoHide, () {
      if (mounted && _c.value.isPlaying) setState(() => _visible = false);
    });
  }

  void _toggleVisible() {
    setState(() => _visible = !_visible);
    if (_visible) _scheduleHide();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _showHud(IconData icon, {String? text, double? fraction}) {
    _hudTimer?.cancel();
    setState(() {
      _hudIcon = icon;
      _hudText = text;
      _hudFraction = fraction;
    });
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hudIcon = null);
    });
  }

  // ---- double-tap seek ----

  Future<void> _onDoubleTapDown(TapDownDetails details, Size box) async {
    if (widget.doubleTapSeek == Duration.zero) return;
    final third = box.width / 3;
    final x = details.localPosition.dx;
    if (x < third) {
      final target = _c.value.position - widget.doubleTapSeek;
      await _c.seekTo(target < Duration.zero ? Duration.zero : target);
      _showHud(Icons.fast_rewind,
          text: '-${widget.doubleTapSeek.inSeconds}s');
    } else if (x > box.width - third) {
      final target = _c.value.position + widget.doubleTapSeek;
      await _c.seekTo(target > _c.value.duration ? _c.value.duration : target);
      _showHud(Icons.fast_forward,
          text: '+${widget.doubleTapSeek.inSeconds}s');
    } else {
      _toggleVisible();
    }
  }

  // ---- fullscreen edge swipes: left = brightness, right = volume ----

  Future<void> _onVerticalDragStart(DragStartDetails details, Size box) async {
    _dragIsBrightness = details.localPosition.dx < box.width / 2;
    _dragAccum = 0;
    if (_dragIsBrightness!) {
      final current = await getScreenBrightness();
      // Remember the pre-swipe value once, so exit can restore it.
      _brightnessBeforeSwipe ??= current;
      _dragStartValue = current < 0 ? 0.5 : current;
    } else {
      _dragStartValue = _c.value.volume;
    }
  }

  Future<void> _onVerticalDragUpdate(
      DragUpdateDetails details, Size box) async {
    final isBrightness = _dragIsBrightness;
    if (isBrightness == null) return;
    // Full-height swipe = full range; up increases.
    _dragAccum += -details.delta.dy / box.height;
    final level = (_dragStartValue + _dragAccum).clamp(0.0, 1.0);
    if (isBrightness) {
      await setScreenBrightness(level);
      _showHud(
        level <= 0.05 ? Icons.brightness_low : Icons.brightness_high,
        fraction: level,
      );
    } else {
      await _c.setVolume(level);
      _showHud(
        level == 0 ? Icons.volume_off : Icons.volume_up,
        fraction: level,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Material: these controls render over a raw Texture, often inside
    // routes/windows with no Material ancestor (fullscreen, PiP restore) —
    // without it Text falls back to the yellow-underline error style.
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final box = constraints.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleVisible,
            onDoubleTapDown: (d) => _onDoubleTapDown(d, box),
            onVerticalDragStart: widget.isFullscreen
                ? (d) => _onVerticalDragStart(d, box)
                : null,
            onVerticalDragUpdate: widget.isFullscreen
                ? (d) => _onVerticalDragUpdate(d, box)
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_visible,
                    child: ValueListenableBuilder<SecureVideoValue>(
                      valueListenable: _c,
                      builder: (context, v, _) => _buildOverlay(context, v),
                    ),
                  ),
                ),
                if (_hudIcon != null) _buildHud(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHud() {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_hudIcon, color: Colors.white, size: 32),
              if (_hudText != null) ...[
                const SizedBox(height: 4),
                Text(_hudText!, style: const TextStyle(color: Colors.white)),
              ],
              if (_hudFraction != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(
                    value: _hudFraction,
                    backgroundColor: Colors.white24,
                    minHeight: 4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context, SecureVideoValue v) {
    final durationMs = v.duration.inMilliseconds.toDouble();
    final positionMs =
        _dragValue ?? v.position.inMilliseconds.clamp(0, durationMs).toDouble();
    final ui = widget.ui;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black45,
            Colors.transparent,
            Colors.transparent,
            Colors.black87,
          ],
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _speedButton(v),
              if (ui != null)
                _iconButton(
                  Icons.aspect_ratio,
                  tooltip: ui.fitLabel,
                  onPressed: () {
                    ui.cycleFit();
                    _showHud(Icons.aspect_ratio, text: ui.fitLabel);
                    _scheduleHide();
                  },
                ),
              if (ui != null && widget.isFullscreen)
                _iconButton(
                  Icons.screen_rotation_alt,
                  tooltip: 'Rotate',
                  onPressed: () {
                    ui.rotate();
                    _scheduleHide();
                  },
                ),
              _iconButton(
                Icons.picture_in_picture_alt,
                tooltip: 'Picture in picture',
                onPressed: () => _c.enterPictureInPicture(),
              ),
              _tracksButton(context),
            ],
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.onPrevious != null)
                  _iconButton(Icons.skip_previous,
                      size: 36, onPressed: widget.onPrevious!),
                IconButton(
                  iconSize: 56,
                  icon: Icon(
                    v.state == SecureVideoState.completed
                        ? Icons.replay
                        : v.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                    color: Colors.white,
                  ),
                  onPressed: () async {
                    if (v.state == SecureVideoState.completed) {
                      await _c.seekTo(Duration.zero);
                      await _c.play();
                    } else if (v.isPlaying) {
                      await _c.pause();
                    } else {
                      await _c.play();
                    }
                    _scheduleHide();
                  },
                ),
                if (widget.onNext != null)
                  _iconButton(Icons.skip_next,
                      size: 36, onPressed: widget.onNext!),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(_fmt(v.position),
                    style:
                        const TextStyle(color: Colors.white, fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: durationMs > 0
                        ? positionMs.clamp(0, durationMs).toDouble()
                        : 0,
                    max: durationMs > 0 ? durationMs : 1,
                    secondaryTrackValue: durationMs > 0
                        ? v.buffered.inMilliseconds
                            .clamp(0, durationMs.toInt())
                            .toDouble()
                        : null,
                    onChangeStart: (_) => _hideTimer?.cancel(),
                    onChanged: (ms) => setState(() => _dragValue = ms),
                    onChangeEnd: (ms) async {
                      setState(() => _dragValue = null);
                      await _c.seekTo(Duration(milliseconds: ms.round()));
                      _scheduleHide();
                    },
                  ),
                ),
                Text(_fmt(v.duration),
                    style:
                        const TextStyle(color: Colors.white, fontSize: 12)),
                _iconButton(
                  v.volume == 0 ? Icons.volume_off : Icons.volume_up,
                  onPressed: () => _c.setVolume(v.volume == 0 ? 1.0 : 0.0),
                ),
                if (widget.onToggleFullscreen != null)
                  _iconButton(
                    widget.isFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    onPressed: widget.onToggleFullscreen!,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconButton(IconData icon,
      {required VoidCallback onPressed, String? tooltip, double size = 24}) {
    return IconButton(
      tooltip: tooltip,
      iconSize: size,
      icon: Icon(icon, color: Colors.white),
      onPressed: onPressed,
    );
  }

  Widget _speedButton(SecureVideoValue v) {
    return PopupMenuButton<double>(
      initialValue: v.speed,
      onSelected: (s) => _c.setSpeed(s),
      itemBuilder: (_) => [0.25, 0.5, 1.0, 1.25, 1.5, 2.0, 3.0]
          .map((s) => PopupMenuItem(value: s, child: Text('${s}x')))
          .toList(),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text('${v.speed}x',
            style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _tracksButton(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.settings, color: Colors.white),
      onPressed: () async {
        _hideTimer?.cancel();
        final audio = await _c.getTracks('audio');
        final subs = await _c.getTracks('subtitle');
        final video = await _c.getTracks('video');
        if (!context.mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          builder: (_) => _TrackSheet(
              controller: _c, audio: audio, subtitles: subs, video: video),
        );
        _scheduleHide();
      },
    );
  }
}

class _TrackSheet extends StatelessWidget {
  const _TrackSheet({
    required this.controller,
    required this.audio,
    required this.subtitles,
    required this.video,
  });

  final SecureVideoController controller;
  final List<VideoTrack> audio;
  final List<VideoTrack> subtitles;
  final List<VideoTrack> video;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          if (video.isNotEmpty)
            _section(context, 'Quality', video, allowOff: true,
                offLabel: 'Auto'),
          if (audio.isNotEmpty) _section(context, 'Audio', audio),
          _section(context, 'Subtitles', subtitles,
              allowOff: true, offLabel: 'Off'),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<VideoTrack> tracks,
      {bool allowOff = false, String offLabel = 'Off'}) {
    final type = tracks.isNotEmpty
        ? tracks.first.type
        : title == 'Subtitles'
            ? 'subtitle'
            : title.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (allowOff)
          ListTile(
            dense: true,
            leading: Icon(tracks.any((t) => t.selected)
                ? Icons.radio_button_unchecked
                : Icons.radio_button_checked),
            title: Text(offLabel),
            onTap: () {
              controller.selectTrack(type, null);
              Navigator.pop(context);
            },
          ),
        ...tracks.map((t) => ListTile(
              dense: true,
              leading: Icon(t.selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: Text(t.displayName),
              onTap: () {
                controller.selectTrack(t.type, t.id);
                Navigator.pop(context);
              },
            )),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../controller.dart';

/// Flutter-drawn playback controls: play/pause, seek bar with buffered
/// indicator, elapsed/total time, speed menu, mute, track selection, PiP.
class SecureVideoControls extends StatefulWidget {
  const SecureVideoControls({
    super.key,
    required this.controller,
    this.autoHide = const Duration(seconds: 3),
  });

  final SecureVideoController controller;
  final Duration autoHide;

  @override
  State<SecureVideoControls> createState() => _SecureVideoControlsState();
}

class _SecureVideoControlsState extends State<SecureVideoControls> {
  bool _visible = true;
  Timer? _hideTimer;
  double? _dragValue;

  SecureVideoController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleVisible,
      child: AnimatedOpacity(
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
    );
  }

  Widget _buildOverlay(BuildContext context, SecureVideoValue v) {
    final durationMs = v.duration.inMilliseconds.toDouble();
    final positionMs =
        _dragValue ?? v.position.inMilliseconds.clamp(0, durationMs).toDouble();

    return DecoratedBox(
      decoration: BoxDecoration(
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
              IconButton(
                icon: const Icon(Icons.picture_in_picture_alt,
                    color: Colors.white),
                onPressed: () => _c.enterPictureInPicture(),
              ),
              _tracksButton(context),
            ],
          ),
          Expanded(
            child: Center(
              child: IconButton(
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
                IconButton(
                  icon: Icon(
                    v.volume == 0 ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white,
                  ),
                  onPressed: () =>
                      _c.setVolume(v.volume == 0 ? 1.0 : 0.0),
                ),
              ],
            ),
          ),
        ],
      ),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// The sample MP4 embeds 2 audio (eng/ben) + 2 subtitle (eng/ben) tracks.
/// Verifies enumeration/selection through the encrypted path and external
/// VTT sideload (Android; iOS reports platformNotSupported).
class TracksScreen extends StatefulWidget {
  const TracksScreen({super.key});

  @override
  State<TracksScreen> createState() => _TracksScreenState();
}

class _TracksScreenState extends State<TracksScreen> {
  final controller = SecureVideoController();
  String _trackReport = 'loading…';
  String _vttStatus = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await controller.initialize(
        source: VideoSource.file(SampleMedia.aesPath),
        scheme: DemoCrypto.aesCtr,
        options: const PlayerOptions(autoPlay: true, looping: true),
      );
      final audio = await controller.getTracks('audio');
      final subs = await controller.getTracks('subtitle');
      setState(() {
        _trackReport = 'audio: ${audio.length} '
            '(${audio.map((t) => t.language ?? '?').join(', ')})\n'
            'subtitles: ${subs.length} '
            '(${subs.map((t) => t.language ?? '?').join(', ')})\n'
            'expected: 2 audio + 2 subtitles → '
            '${audio.length == 2 && subs.length == 2 ? 'PASS' : 'FAIL'}';
      });
    } on SecureVideoException catch (e) {
      setState(() => _trackReport = 'init failed: ${e.code.name}');
    }
  }

  Future<void> _sideloadVtt() async {
    try {
      await controller.addExternalSubtitle(SampleMedia.externalVttPath,
          mimeType: 'text/vtt', language: 'en');
      final subs = await controller.getTracks('subtitle');
      setState(() => _vttStatus =
          'VTT added → now ${subs.length} subtitle tracks (PASS)');
    } on SecureVideoException catch (e) {
      setState(() => _vttStatus = e.code == SecureVideoErrorCode.platformNotSupported
          ? 'platformNotSupported (expected on iOS — PASS)'
          : 'FAIL: ${e.code.name} ${e.message}');
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tracks & subtitles')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  StatusChip(controller: controller),
                  const SizedBox(width: 8),
                  OutlinedButton(
                      onPressed: _sideloadVtt,
                      child: const Text('Sideload VTT')),
                ]),
                const SizedBox(height: 4),
                Text(_trackReport),
                if (_vttStatus.isNotEmpty) Text(_vttStatus),
                const Text('Use the ⚙ button in the controls to switch '
                    'audio/subtitles.'),
              ],
            ),
          ),
          Expanded(
            child: SecureVideoPlayer(
              controller: controller,
              // App-lock demo: after leaving fullscreen, re-apply portrait
              // instead of unlocking every orientation.
              restoreOrientationsAfterFullscreen: const [
                DeviceOrientation.portraitUp,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

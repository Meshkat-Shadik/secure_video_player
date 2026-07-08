import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Random-seek hammer against AES-CTR content: proves position-addressable
/// decryption (seek to byte N without reading 0..N). Plus speed cycling
/// and loop verification.
class SeekStressScreen extends StatefulWidget {
  const SeekStressScreen({super.key});

  @override
  State<SeekStressScreen> createState() => _SeekStressScreenState();
}

class _SeekStressScreenState extends State<SeekStressScreen> {
  final controller = SecureVideoController();
  Timer? _hammer;
  int _seeks = 0;

  @override
  void initState() {
    super.initState();
    controller
        .initialize(
          source: VideoSource.file(SampleMedia.aesPath),
          scheme: DemoCrypto.aesCtr,
          options: const PlayerOptions(autoPlay: true, looping: true),
        )
        .catchError((_) {});
  }

  void _toggleHammer() {
    if (_hammer != null) {
      _hammer!.cancel();
      setState(() => _hammer = null);
      return;
    }
    final random = Random();
    _hammer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final duration = controller.value.duration;
      if (duration == Duration.zero) return;
      controller.seekTo(Duration(
          milliseconds: random.nextInt(duration.inMilliseconds)));
      setState(() => _seeks++);
    });
    setState(() {});
  }

  @override
  void dispose() {
    _hammer?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Seek hammer + speed + loop')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip(controller: controller),
                FilledButton.icon(
                  icon: Icon(_hammer == null ? Icons.bolt : Icons.stop),
                  label: Text(_hammer == null
                      ? 'Start hammer'
                      : 'Stop ($_seeks seeks)'),
                  onPressed: _toggleHammer,
                ),
                for (final speed in [0.25, 1.0, 2.0, 3.0])
                  OutlinedButton(
                    onPressed: () => controller.setSpeed(speed),
                    child: Text('${speed}x'),
                  ),
              ],
            ),
          ),
          Expanded(child: SecureVideoPlayer(controller: controller)),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Default vs lowRam BufferConfig side by side. On a 1 GB device the lowRam
/// player should start faster and hold ~half the buffered runway.
class BufferScreen extends StatefulWidget {
  const BufferScreen({super.key});

  @override
  State<BufferScreen> createState() => _BufferScreenState();
}

class _BufferScreenState extends State<BufferScreen> {
  final defaultController = SecureVideoController();
  final lowRamController = SecureVideoController();

  @override
  void initState() {
    super.initState();
    defaultController
        .initialize(
          source: VideoSource.file(SampleMedia.aesPath),
          scheme: DemoCrypto.aesCtr,
          options: const PlayerOptions(autoPlay: true, looping: true),
        )
        .catchError((_) {});
    lowRamController
        .initialize(
          source: VideoSource.file(SampleMedia.aesPath),
          scheme: DemoCrypto.aesCtr,
          options: const PlayerOptions(
              autoPlay: true, looping: true, buffer: BufferConfig.lowRam()),
        )
        .catchError((_) {});
  }

  @override
  void dispose() {
    defaultController.dispose();
    lowRamController.dispose();
    super.dispose();
  }

  Widget _pane(String label, String config, SecureVideoController c) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(config, style: const TextStyle(fontSize: 11)),
          StatusChip(controller: c),
          ValueListenableBuilder<SecureVideoValue>(
            valueListenable: c,
            builder: (context, v, child) => Text(
                'buffered: ${v.buffered.inSeconds}s / pos: '
                '${v.position.inSeconds}s',
                style: const TextStyle(fontSize: 11)),
          ),
          Expanded(child: SecureVideoPlayer(controller: c, showControls: false)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Buffer tuning')),
      body: Column(
        children: [
          _pane('Default', 'min 15s / max 30s / playback 2.5s',
              defaultController),
          const Divider(),
          _pane('BufferConfig.lowRam()', 'min 8s / max 15s / playback 1.5s',
              lowRamController),
        ],
      ),
    );
  }
}

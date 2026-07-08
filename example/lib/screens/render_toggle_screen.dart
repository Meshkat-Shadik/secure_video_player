import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Same encrypted file through both render paths. Texture = Flutter
/// controls/compositing; PlatformView = native controls (and iOS PiP).
class RenderToggleScreen extends StatefulWidget {
  const RenderToggleScreen({super.key});

  @override
  State<RenderToggleScreen> createState() => _RenderToggleScreenState();
}

class _RenderToggleScreenState extends State<RenderToggleScreen> {
  SecureVideoController? controller;
  RenderMode mode = RenderMode.texture;

  @override
  void initState() {
    super.initState();
    _recreate();
  }

  Future<void> _recreate() async {
    final old = controller;
    final fresh = SecureVideoController();
    setState(() => controller = fresh);
    await old?.dispose();
    await fresh
        .initialize(
          source: VideoSource.file(SampleMedia.aesPath),
          scheme: DemoCrypto.aesCtr,
          options: PlayerOptions(
              autoPlay: true, looping: true, renderMode: mode),
        )
        .catchError((_) {});
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Texture vs PlatformView')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                if (controller != null) StatusChip(controller: controller!),
                const Spacer(),
                SegmentedButton<RenderMode>(
                  segments: const [
                    ButtonSegment(
                        value: RenderMode.texture, label: Text('Texture')),
                    ButtonSegment(
                        value: RenderMode.platformView,
                        label: Text('PlatformView')),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) {
                    mode = s.first;
                    _recreate();
                  },
                ),
              ],
            ),
          ),
          if (controller != null)
            Expanded(child: SecureVideoPlayer(controller: controller!)),
        ],
      ),
    );
  }
}

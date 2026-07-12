import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Four decrypting players at once — multi-instance support plus decode/
/// decrypt load. On a 1 GB device expect all four to still reach READY
/// (lowRam buffers keep the memory bill ~4x smaller than defaults).
class MultiPlayerScreen extends StatefulWidget {
  const MultiPlayerScreen({super.key});

  @override
  State<MultiPlayerScreen> createState() => _MultiPlayerScreenState();
}

class _MultiPlayerScreenState extends State<MultiPlayerScreen> {
  final controllers = List.generate(4, (_) => SecureVideoController());

  @override
  void initState() {
    super.initState();
    final sources = [
      (SampleMedia.plainPath, const CryptoScheme.none()),
      (SampleMedia.xorPath, DemoCrypto.xorLegacy),
      (SampleMedia.aesPath, DemoCrypto.aesCtr),
      (SampleMedia.plainPath, const CryptoScheme.none()),
    ];
    for (var i = 0; i < 4; i++) {
      controllers[i]
          .initialize(
            source: VideoSource.file(sources[i].$1),
            scheme: sources[i].$2,
            options: const PlayerOptions(
              autoPlay: true,
              looping: true,
              buffer: BufferConfig.lowRam(),
            ),
          )
          .catchError((_) {});
    }
  }

  @override
  void dispose() {
    for (final c in controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('4 simultaneous players')),
      body: GridView.count(
        crossAxisCount: 2,
        childAspectRatio: 16 / 12,
        children: [
          for (final c in controllers)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                children: [
                  StatusChip(controller: c),
                  Expanded(
                      child:
                          SecureVideoPlayer(controller: c, showControls: false)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

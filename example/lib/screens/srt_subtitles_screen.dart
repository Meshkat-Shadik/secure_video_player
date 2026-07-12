import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// SRT subtitles demo: load SRT, render overlay, adjust delay in real time.
class SrtSubtitlesScreen extends StatefulWidget {
  const SrtSubtitlesScreen({super.key});

  @override
  State<SrtSubtitlesScreen> createState() => _SrtSubtitlesScreenState();
}

class _SrtSubtitlesScreenState extends State<SrtSubtitlesScreen> {
  final controller = SecureVideoController();
  List<SubtitleCue> _cues = [];
  Duration _delay = Duration.zero;
  bool _loaded = false;

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
        options: const PlayerOptions(autoPlay: true, looping: false),
      );
      // Real SRT text through the real parser (CRLF, multi-line, tags).
      _cues = SrtSubtitles.fromString('''
1
00:00:00,000 --> 00:00:05,000
Welcome to the video

2
00:00:05,000 --> 00:00:10,000
This is a <i>demo</i> subtitle
rendered fully in Flutter

3
00:00:10,000 --> 00:00:20,000
<b>Bold subtitle</b> over encrypted video

4
00:00:20,000 --> 00:00:30,000
Drag the delay slider to shift timing
''');
      setState(() => _loaded = true);
    } on SecureVideoException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Init failed: ${e.code.name}')),
        );
      }
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
      appBar: AppBar(title: const Text('SRT subtitles + delay')),
      body: _loaded
          ? Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatusChip(controller: controller),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('Delay:'),
                          Expanded(
                            child: Slider(
                              value: _delay.inMilliseconds.toDouble(),
                              min: -2000,
                              max: 2000,
                              onChanged: (v) {
                                setState(() {
                                  _delay = Duration(milliseconds: v.toInt());
                                });
                              },
                            ),
                          ),
                          Text(
                            '${_delay.inMilliseconds}ms',
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      const Text(
                        'Negative = earlier, positive = later',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      SecureVideoPlayer(controller: controller),
                      Positioned(
                        bottom: 60,
                        left: 8,
                        right: 8,
                        child: SrtSubtitleOverlay(
                          controller: controller,
                          subtitles: _cues,
                          delay: _delay,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(
                                offset: Offset(1, 1),
                                color: Colors.black87,
                                blurRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

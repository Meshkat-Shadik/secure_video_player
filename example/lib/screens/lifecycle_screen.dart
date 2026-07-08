import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// PiP, background audio, screen-capture protection, and home/resume
/// lifecycle — the "does it survive the OS" screen.
class LifecycleScreen extends StatefulWidget {
  const LifecycleScreen({super.key});

  @override
  State<LifecycleScreen> createState() => _LifecycleScreenState();
}

class _LifecycleScreenState extends State<LifecycleScreen> {
  final controller = SecureVideoController();
  bool _background = false;
  bool _secure = false;
  String _pipStatus = '';

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

  @override
  void dispose() {
    if (_secure) setScreenCaptureProtection(false);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PiP / background / secure')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(children: [
                  StatusChip(controller: controller),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.picture_in_picture_alt),
                    label: const Text('Enter PiP'),
                    onPressed: () async {
                      final ok = await controller.enterPictureInPicture();
                      setState(() => _pipStatus = ok
                          ? 'PiP entered'
                          : 'PiP unavailable '
                              '(iOS: use PlatformView mode)');
                    },
                  ),
                ]),
                SwitchListTile(
                  dense: true,
                  title: const Text('Background playback '
                      '(press home — audio continues)'),
                  value: _background,
                  onChanged: (v) {
                    setState(() => _background = v);
                    controller.setBackgroundPlayback(v);
                  },
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('Screen-capture protection '
                      '(screenshot goes black)'),
                  value: _secure,
                  onChanged: (v) {
                    setState(() => _secure = v);
                    setScreenCaptureProtection(v);
                  },
                ),
                if (_pipStatus.isNotEmpty) Text(_pipStatus),
                const Text(
                  'Manual checks: press home mid-playback (pauses unless '
                  'background enabled, resumes on return), rotate the device '
                  '(position survives).',
                  style: TextStyle(fontSize: 12),
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

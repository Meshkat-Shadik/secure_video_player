import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Media controls demo: show Android notification + iOS now-playing.
class MediaControlsScreen extends StatefulWidget {
  const MediaControlsScreen({super.key});

  @override
  State<MediaControlsScreen> createState() => _MediaControlsScreenState();
}

class _MediaControlsScreenState extends State<MediaControlsScreen> {
  final controller = SecureVideoController();
  final _titleController = TextEditingController(text: 'Sample Video');
  final _artistController = TextEditingController(text: 'Demo Artist');
  bool _controlsEnabled = false;

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
    if (_controlsEnabled) {
      controller.updateMediaControls(
        MediaControlsOptions(enabled: false),
      );
    }
    _titleController.dispose();
    _artistController.dispose();
    controller.dispose();
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _controlsEnabled = !_controlsEnabled);
    if (_controlsEnabled) {
      _updateMetadata();
    } else {
      controller.updateMediaControls(
        MediaControlsOptions(enabled: false),
      );
    }
  }

  void _updateMetadata() {
    if (_controlsEnabled) {
      controller.updateMediaControls(
        MediaControlsOptions(
          enabled: true,
          title: _titleController.text,
          artist: _artistController.text,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Media controls')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusChip(controller: controller),
                const SizedBox(height: 12),
                SwitchListTile(
                  dense: true,
                  title: const Text('Enable system media controls'),
                  subtitle: _controlsEnabled
                      ? const Text('Android: notification, iOS: lock-screen now-playing')
                      : null,
                  value: _controlsEnabled,
                  onChanged: (_) => _toggleControls(),
                ),
                if (_controlsEnabled) ...[
                  const SizedBox(height: 12),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Title'),
                    controller: _titleController,
                    onChanged: (_) => _updateMetadata(),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Artist/Author'),
                    controller: _artistController,
                    onChanged: (_) => _updateMetadata(),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Android: Pull down notification drawer to see control buttons (play/pause/seek).\n'
                    'iOS: Lock the device or pull Control Center to see Now Playing info.\n'
                    'Both: System remotes also work (headphone buttons, car interface).',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: SecureVideoPlayer(controller: controller)),
        ],
      ),
    );
  }
}

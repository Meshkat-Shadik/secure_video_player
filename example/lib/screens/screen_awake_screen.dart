import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Screen awake demo: keepScreenAwakeWhilePlaying + manual override.
class ScreenAwakeScreen extends StatefulWidget {
  const ScreenAwakeScreen({super.key});

  @override
  State<ScreenAwakeScreen> createState() => _ScreenAwakeScreenState();
}

class _ScreenAwakeScreenState extends State<ScreenAwakeScreen> {
  final controller = SecureVideoController();
  bool _keepAwakeOption = true;
  bool? _overrideAwake;
  String _log = '';

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
        options: PlayerOptions(
          autoPlay: true,
          looping: true,
          keepScreenAwakeWhilePlaying: _keepAwakeOption,
        ),
      );
      _addLog('Initialized with keepScreenAwakeWhilePlaying=$_keepAwakeOption');
    } on SecureVideoException catch (e) {
      _addLog('Init failed: ${e.code.name}');
    }
  }

  void _addLog(String msg) {
    setState(() {
      _log = '$msg\n$_log';
    });
  }

  void _toggleOption() {
    setState(() {
      _keepAwakeOption = !_keepAwakeOption;
      _addLog('Option changed: keepScreenAwakeWhilePlaying=$_keepAwakeOption');
    });
  }

  void _forceOn() {
    controller.setKeepScreenAwake(true);
    setState(() {
      _overrideAwake = true;
      _addLog('Override: screen ON (forced)');
    });
  }

  void _forceOff() {
    controller.setKeepScreenAwake(false);
    setState(() {
      _overrideAwake = false;
      _addLog('Override: screen OFF (forced)');
    });
  }

  void _automatic() {
    controller.setKeepScreenAwake(null);
    setState(() {
      _overrideAwake = null;
      _addLog('Override: automatic (follow option)');
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Screen awake while playing')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusChip(controller: controller),
                const SizedBox(height: 12),
                // Option toggle
                SwitchListTile(
                  dense: true,
                  title: const Text('keepScreenAwakeWhilePlaying (option)'),
                  subtitle: Text('Currently: $_keepAwakeOption'),
                  value: _keepAwakeOption,
                  onChanged: (_) => _toggleOption(),
                ),
                const SizedBox(height: 8),
                // Manual overrides
                const Text('Manual override:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: _forceOn,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _overrideAwake == true ? Colors.green : null,
                      ),
                      child: const Text('Force ON'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _forceOff,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _overrideAwake == false ? Colors.red : null,
                      ),
                      child: const Text('Force OFF'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _automatic,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _overrideAwake == null ? Colors.blue : null,
                      ),
                      child: const Text('Auto'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Android: FLAG_KEEP_SCREEN_ON on activity.window\n'
                  'iOS: UIApplication.isIdleTimerDisabled\n'
                  'Behavior: when playing & option=true, screen stays on (unless forced OFF).',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: SecureVideoPlayer(controller: controller),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Log:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Text(
                        _log.isEmpty ? '(empty)' : _log,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

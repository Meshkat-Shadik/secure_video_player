import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Progress triggers (fire callback at position/percent) + sleep timer demo.
class ProgressTriggersAndSleepTimerScreen extends StatefulWidget {
  const ProgressTriggersAndSleepTimerScreen({super.key});

  @override
  State<ProgressTriggersAndSleepTimerScreen> createState() =>
      _ProgressTriggersAndSleepTimerScreenState();
}

class _ProgressTriggersAndSleepTimerScreenState
    extends State<ProgressTriggersAndSleepTimerScreen> {
  final controller = SecureVideoController();
  final _events = <String>[];
  int? _triggerSeconds;
  int? _sleepSeconds;
  TriggerHandle? _triggerHandle;

  @override
  void initState() {
    super.initState();
    controller
        .initialize(
          source: VideoSource.file(SampleMedia.aesPath),
          scheme: DemoCrypto.aesCtr,
          options: const PlayerOptions(autoPlay: true, looping: false),
        )
        .catchError((_) {});
  }

  @override
  void dispose() {
    _triggerHandle?.cancel();
    controller.dispose();
    super.dispose();
  }

  void _addTrigger() {
    if (_triggerSeconds == null || _triggerSeconds! < 0) return;
    _triggerHandle?.cancel();
    final triggerPos = Duration(seconds: _triggerSeconds!);
    _triggerHandle = controller.addProgressTrigger(
      ProgressTrigger.at(triggerPos, () {
        setState(() {
          _events.add('✓ Trigger fired @ ${triggerPos.inSeconds}s');
        });
      }),
    );
    setState(() {
      _events.add('+ Trigger added @ ${_triggerSeconds}s');
    });
  }

  void _setSleepTimer() {
    if (_sleepSeconds == null || _sleepSeconds! <= 0) return;
    controller.setSleepTimer(Duration(seconds: _sleepSeconds!), onFired: () {
      setState(() {
        _events.add('⏰ Sleep timer fired — paused');
      });
    });
    setState(() {
      _events.add('+ Sleep timer set: ${_sleepSeconds}s');
    });
  }

  void _cancelSleepTimer() {
    controller.cancelSleepTimer();
    setState(() {
      _events.add('- Sleep timer cancelled');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Progress triggers + sleep timer')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusChip(controller: controller),
                const SizedBox(height: 12),
                // Trigger at position
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'Trigger at (sec)'),
                        onChanged: (s) =>
                            _triggerSeconds = int.tryParse(s) ?? 0,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _addTrigger,
                      child: const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Sleep timer
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'Sleep timer (sec)'),
                        onChanged: (s) =>
                            _sleepSeconds = int.tryParse(s) ?? 0,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _setSleepTimer,
                      child: const Text('Set'),
                    ),
                    const SizedBox(width: 4),
                    ElevatedButton(
                      onPressed: _cancelSleepTimer,
                      child: const Text('Cancel'),
                    ),
                  ],
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
                  const Text('Events:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _events.length,
                      itemBuilder: (context, i) => Text(
                        _events[_events.length - 1 - i],
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
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

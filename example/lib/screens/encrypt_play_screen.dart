import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Full pipeline: encrypt the plain file with live progress, verify the
/// ciphertext differs from the plaintext, then play the encrypted result.
class EncryptPlayScreen extends StatefulWidget {
  const EncryptPlayScreen({super.key});

  @override
  State<EncryptPlayScreen> createState() => _EncryptPlayScreenState();
}

class _EncryptPlayScreenState extends State<EncryptPlayScreen> {
  double _progress = 0;
  String _status = 'idle';
  String? _outputPath;
  SecureVideoController? _controller;

  Future<void> _run() async {
    setState(() {
      _status = 'encrypting';
      _progress = 0;
      _controller?.dispose();
      _controller = null;
    });

    final dir = await getApplicationDocumentsDirectory();
    final out = '${dir.path}/svp_samples/encrypt_play_output.enc';
    File(out).parent.createSync(recursive: true);
    if (File(out).existsSync()) File(out).deleteSync();

    final op = await SecureVideoEncryptor.encrypt(
        SampleMedia.plainPath, out, DemoCrypto.aesCtr);
    try {
      await for (final p in op.progress) {
        setState(() => _progress = p.fraction);
      }
    } on SecureVideoException catch (e) {
      setState(() => _status = 'encrypt failed: ${e.code.name}');
      return;
    }

    // Sanity: ciphertext must differ from plaintext, same length.
    final plain = File(SampleMedia.plainPath);
    final cipher = File(out);
    final sameLength = plain.lengthSync() == cipher.lengthSync();
    final plainHead = plain.openSync().readSync(1024);
    final cipherHead = cipher.openSync().readSync(1024);
    var differs = false;
    for (var i = 0; i < 1024; i++) {
      if (plainHead[i] != cipherHead[i]) {
        differs = true;
        break;
      }
    }
    if (!sameLength || !differs) {
      setState(() => _status =
          'FAIL: sameLength=$sameLength differs=$differs');
      return;
    }

    final controller = SecureVideoController();
    setState(() {
      _outputPath = out;
      _controller = controller;
      _status = 'playing ciphertext';
    });
    await controller
        .initialize(
          source: VideoSource.file(out),
          scheme: DemoCrypto.aesCtr,
          options: const PlayerOptions(autoPlay: true),
        )
        .catchError((_) {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Encrypt → play')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    FilledButton(
                        onPressed: _run, child: const Text('Encrypt + play')),
                    const SizedBox(width: 12),
                    Expanded(child: LinearProgressIndicator(value: _progress)),
                  ],
                ),
                const SizedBox(height: 6),
                Text('$_status'
                    '${_outputPath != null ? '\n$_outputPath' : ''}'),
              ],
            ),
          ),
          if (_controller != null) ...[
            StatusChip(controller: _controller!),
            Expanded(child: SecureVideoPlayer(controller: _controller!)),
          ] else
            const Expanded(
                child: Center(child: Text('Press "Encrypt + play"'))),
        ],
      ),
    );
  }
}

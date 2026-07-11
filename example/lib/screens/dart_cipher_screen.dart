import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../sample_media.dart';
import 'common.dart';

/// Custom Dart cipher demo: register DartCipherDelegate, play encrypted video.
class DartCipherScreen extends StatefulWidget {
  const DartCipherScreen({super.key});

  @override
  State<DartCipherScreen> createState() => _DartCipherScreenState();
}

class _DartCipherScreenState extends State<DartCipherScreen> {
  final controller = SecureVideoController();
  String _status = 'Initializing…';
  DartCipherRegistration? _registration;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // Create a simple repeating-XOR cipher in Dart
      const channelId = 'demo_dart_xor_cipher';
      final key = Uint8List.fromList([0x5A, 0xC3, 0x0F, 0x99, 0x42]);

      final delegate = _SimpleDartXorCipher(key);
      _registration = DartCipher.register(channelId, delegate);

      // Initialize player with dartProxy scheme
      await controller.initialize(
        source: VideoSource.file(SampleMedia.customPath),
        scheme: CryptoScheme.dartProxy(channelId: channelId),
        options: const PlayerOptions(autoPlay: true, looping: false),
      );

      setState(() => _status = 'Dart cipher registered and playing');
    } on SecureVideoException catch (e) {
      setState(() => _status = 'Error: ${e.code.name} — ${e.message}');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  @override
  void dispose() {
    _registration?.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Custom Dart cipher')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusChip(controller: controller),
                const SizedBox(height: 8),
                Text(
                  _status,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This screen:\n'
                  '1. Registers a Dart-side XOR cipher via DartCipher.register()\n'
                  '2. Plays an encrypted file (SampleMedia.customPath)\n'
                  '3. Decrypt happens in Dart on the Dart thread via BasicMessageChannel\n'
                  '4. Per-chunk IPC; native schemes are faster (demo only)',
                  style: TextStyle(fontSize: 11),
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

/// Simple repeating-XOR cipher for demo. Production use: proper AEAD.
class _SimpleDartXorCipher extends DartCipherDelegate {
  final Uint8List key;

  _SimpleDartXorCipher(this.key);

  @override
  Uint8List decrypt(Uint8List ciphertext, int fileOffset) {
    final plaintext = Uint8List(ciphertext.length);
    for (int i = 0; i < ciphertext.length; i++) {
      plaintext[i] = ciphertext[i] ^ key[(fileOffset + i) % key.length];
    }
    return plaintext;
  }

  @override
  Uint8List encrypt(Uint8List plaintext, int fileOffset) {
    // XOR is symmetric
    return decrypt(plaintext, fileOffset);
  }
}

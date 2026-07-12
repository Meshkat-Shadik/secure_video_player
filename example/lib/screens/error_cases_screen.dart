import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// Every failure mode must surface as a typed SecureVideoException —
/// never a crash, never a silent hang.
class ErrorCasesScreen extends StatelessWidget {
  const ErrorCasesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cases = <(String, String, CryptoScheme, SecureVideoErrorCode)>[
      (
        'Wrong AES key',
        SampleMedia.aesPath,
        DemoCrypto.aesCtrWrongKey,
        SecureVideoErrorCode.corruptStream,
      ),
      (
        'Truncated file',
        SampleMedia.truncatedPath,
        DemoCrypto.aesCtr,
        SecureVideoErrorCode.corruptStream,
      ),
      (
        'Missing file',
        '/nonexistent/video.enc',
        DemoCrypto.aesCtr,
        SecureVideoErrorCode.fileNotFound,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Error cases')),
      body: ListView(
        children: [
          for (final c in cases)
            _ErrorCaseTile(
                title: c.$1, path: c.$2, scheme: c.$3, expect: c.$4),
        ],
      ),
    );
  }
}

class _ErrorCaseTile extends StatefulWidget {
  const _ErrorCaseTile({
    required this.title,
    required this.path,
    required this.scheme,
    required this.expect,
  });

  final String title;
  final String path;
  final CryptoScheme scheme;
  final SecureVideoErrorCode expect;

  @override
  State<_ErrorCaseTile> createState() => _ErrorCaseTileState();
}

class _ErrorCaseTileState extends State<_ErrorCaseTile> {
  final controller = SecureVideoController();

  @override
  void initState() {
    super.initState();
    controller
        .initialize(
          source: VideoSource.file(widget.path),
          scheme: widget.scheme,
          options: const PlayerOptions(autoPlay: true),
        )
        .catchError((_) {});
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.title),
      subtitle: ValueListenableBuilder<SecureVideoValue>(
        valueListenable: controller,
        builder: (context, v, child) => Text(
            v.error?.message ?? 'expecting ${widget.expect.name}…',
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ),
      trailing: StatusChip(controller: controller, expectError: widget.expect),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// One tab per scheme; each must reach READY and play. Proves each cipher's
/// on-the-fly decryption produces a decodable stream.
class SchemeMatrixScreen extends StatelessWidget {
  const SchemeMatrixScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cases = <(String, String, CryptoScheme)>[
      ('Plain', SampleMedia.plainPath, const CryptoScheme.none()),
      ('XOR legacy', SampleMedia.xorPath, DemoCrypto.xorLegacy),
      ('AES-CTR', SampleMedia.aesPath, DemoCrypto.aesCtr),
      ('Custom', SampleMedia.customPath, DemoCrypto.customRepeatingXor),
    ];

    return DefaultTabController(
      length: cases.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Scheme matrix'),
          bottom: TabBar(
              isScrollable: true,
              tabs: [for (final c in cases) Tab(text: c.$1)]),
        ),
        body: TabBarView(
          children: [
            for (final c in cases) _SchemeCase(path: c.$2, scheme: c.$3),
          ],
        ),
      ),
    );
  }
}

class _SchemeCase extends StatefulWidget {
  const _SchemeCase({required this.path, required this.scheme});

  final String path;
  final CryptoScheme scheme;

  @override
  State<_SchemeCase> createState() => _SchemeCaseState();
}

class _SchemeCaseState extends State<_SchemeCase>
    with AutomaticKeepAliveClientMixin {
  final controller = SecureVideoController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    controller
        .initialize(
          source: VideoSource.file(widget.path),
          scheme: widget.scheme,
          options: const PlayerOptions(autoPlay: true, looping: true),
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
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: StatusChip(controller: controller),
        ),
        Text('scheme: ${widget.scheme.type}',
            style: Theme.of(context).textTheme.bodySmall),
        Expanded(child: SecureVideoPlayer(controller: controller)),
      ],
    );
  }
}

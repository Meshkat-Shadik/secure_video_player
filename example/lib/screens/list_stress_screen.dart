import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

import '../demo_crypto.dart';
import '../sample_media.dart';
import 'common.dart';

/// 20-row list where each visible row owns a live decrypting player.
/// Scrolling creates and disposes native players constantly — the recycle
/// stress that broke the original Hulkenstein single-instance design.
class ListStressScreen extends StatelessWidget {
  const ListStressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('List recycling stress')),
      body: ListView.builder(
        itemCount: 20,
        // Small cache so off-screen rows really dispose.
        cacheExtent: 0,
        itemBuilder: (context, i) => _ListPlayerTile(index: i),
      ),
    );
  }
}

class _ListPlayerTile extends StatefulWidget {
  const _ListPlayerTile({required this.index});

  final int index;

  @override
  State<_ListPlayerTile> createState() => _ListPlayerTileState();
}

class _ListPlayerTileState extends State<_ListPlayerTile> {
  final controller = SecureVideoController();

  @override
  void initState() {
    super.initState();
    controller
        .initialize(
          source: VideoSource.file(
              widget.index.isEven ? SampleMedia.aesPath : SampleMedia.xorPath),
          scheme:
              widget.index.isEven ? DemoCrypto.aesCtr : DemoCrypto.xorLegacy,
          options: PlayerOptions(
            autoPlay: true,
            looping: true,
            buffer: const BufferConfig.lowRam(),
            startPosition: Duration(seconds: widget.index % 20),
          ),
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
    return SizedBox(
      height: 220,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.all(8),
        child: Column(
          children: [
            ListTile(
              dense: true,
              title: Text('Row ${widget.index} · '
                  '${widget.index.isEven ? 'aesCtr' : 'xorLegacy'}'),
              trailing: StatusChip(controller: controller),
            ),
            Expanded(
                child: SecureVideoPlayer(
                    controller: controller, showControls: false)),
          ],
        ),
      ),
    );
  }
}

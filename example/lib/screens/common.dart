import 'package:flutter/material.dart';
import 'package:secure_video_player/secure_video_player.dart';

/// Green PASS / red FAIL chip driven by controller state — every screen
/// shows one so a human (or screenshot diff) can verify at a glance.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.controller, this.expectError});

  final SecureVideoController controller;

  /// When set, PASS means "failed with exactly this code".
  final SecureVideoErrorCode? expectError;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SecureVideoValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        final (label, color) = _evaluate(v);
        return Chip(
          label: Text(label, style: const TextStyle(color: Colors.white)),
          backgroundColor: color,
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }

  (String, Color) _evaluate(SecureVideoValue v) {
    if (expectError != null) {
      if (v.error?.code == expectError) {
        return ('PASS · ${expectError!.name}', Colors.green);
      }
      if (v.state == SecureVideoState.error) {
        return ('FAIL · got ${v.error?.code.name}', Colors.red);
      }
      if (v.state == SecureVideoState.ready ||
          v.state == SecureVideoState.completed) {
        return ('FAIL · played, expected error', Colors.red);
      }
      return ('WAITING', Colors.orange);
    }
    return switch (v.state) {
      SecureVideoState.ready ||
      SecureVideoState.completed =>
        ('PASS · ${v.duration.inSeconds}s ${v.size.width.toInt()}x${v.size.height.toInt()}', Colors.green),
      SecureVideoState.error => ('FAIL · ${v.error?.code.name}', Colors.red),
      _ => ('LOADING', Colors.orange),
    };
  }
}

/// Boilerplate: init a controller in initState, dispose it, render player +
/// status chip. Screens with one player reuse this.
class SinglePlayerScaffold extends StatefulWidget {
  const SinglePlayerScaffold({
    super.key,
    required this.title,
    required this.init,
    this.expectError,
    this.footer,
  });

  final String title;
  final Future<void> Function(SecureVideoController) init;
  final SecureVideoErrorCode? expectError;
  final Widget Function(BuildContext, SecureVideoController)? footer;

  @override
  State<SinglePlayerScaffold> createState() => _SinglePlayerScaffoldState();
}

class _SinglePlayerScaffoldState extends State<SinglePlayerScaffold> {
  final controller = SecureVideoController();

  @override
  void initState() {
    super.initState();
    // Errors land in controller.value.error; StatusChip reports them.
    widget.init(controller).catchError((_) {});
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: StatusChip(
                controller: controller, expectError: widget.expectError),
          ),
          Expanded(child: SecureVideoPlayer(controller: controller)),
          if (widget.footer != null) widget.footer!(context, controller),
        ],
      ),
    );
  }
}

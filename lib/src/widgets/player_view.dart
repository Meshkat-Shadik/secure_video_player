import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../player_options.dart';
import '../protocol.dart';
import 'controls.dart';

/// Renders a [SecureVideoController]'s video. Texture mode composes like any
/// widget; platformView mode embeds the native player view (with native
/// controls) — set `showControls: false` there to avoid double controls.
class SecureVideoPlayer extends StatelessWidget {
  const SecureVideoPlayer({
    super.key,
    required this.controller,
    this.showControls = true,
    this.fit = BoxFit.contain,
    this.allowFullscreen = true,
    this.fullscreenOrientations,
    this.restoreOrientationsAfterFullscreen,
  }) : _isFullscreen = false;

  const SecureVideoPlayer._fullscreen({
    required this.controller,
    required this.showControls,
    required this.fit,
  })  : allowFullscreen = true,
        fullscreenOrientations = null,
        restoreOrientationsAfterFullscreen = null,
        _isFullscreen = true;

  final SecureVideoController controller;
  final bool showControls;
  final BoxFit fit;

  /// Show the fullscreen button in the Flutter controls (texture mode).
  final bool allowFullscreen;

  /// Orientations forced while fullscreen. Default (null): landscape, or
  /// portrait when the video is taller than wide.
  final List<DeviceOrientation>? fullscreenOrientations;

  /// Orientations re-applied when the player exits fullscreen. Set this to
  /// your app's orientations (e.g. `[DeviceOrientation.portraitUp]`) if the
  /// app runs under an orientation lock — otherwise leaving fullscreen would
  /// override it. Default (null) restores all orientations (non-breaking).
  final List<DeviceOrientation>? restoreOrientationsAfterFullscreen;

  final bool _isFullscreen;

  Future<void> _enterFullscreen(BuildContext context) async {
    final orientations = fullscreenOrientations ??
        (controller.value.aspectRatio < 1
            ? const [DeviceOrientation.portraitUp]
            : const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(orientations);
    if (!context.mounted) return;

    await Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) =>
            FadeTransition(
          opacity: animation,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SecureVideoPlayer._fullscreen(
              controller: controller,
              showControls: showControls,
              fit: fit,
            ),
          ),
        ),
      ),
    );

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(
        restoreOrientationsAfterFullscreen ?? DeviceOrientation.values);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SecureVideoValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (value.state == SecureVideoState.error) {
          return _ErrorView(message: value.error?.message ?? 'Playback error');
        }
        if (!value.isInitialized || controller.playerId == null) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final Widget video;
        if (controller.renderMode == RenderMode.platformView) {
          video = _platformView(controller.playerId!);
        } else {
          video = FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: value.size.width > 0 ? value.size.width : 16,
              height: value.size.height > 0 ? value.size.height : 9,
              child: Texture(textureId: controller.textureId!),
            ),
          );
        }

        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              video,
              if (value.state == SecureVideoState.buffering)
                const Center(child: CircularProgressIndicator()),
              // Native controls own the platformView surface; Flutter
              // controls would fight them for gestures.
              if (showControls &&
                  controller.renderMode == RenderMode.texture)
                SecureVideoControls(
                  controller: controller,
                  isFullscreen: _isFullscreen,
                  onToggleFullscreen: !allowFullscreen
                      ? null
                      : () {
                          if (_isFullscreen) {
                            Navigator.of(context, rootNavigator: true).pop();
                          } else {
                            _enterFullscreen(context);
                          }
                        },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _platformView(int playerId) {
    const viewType = SvpChannels.platformViewType;
    final params = {'playerId': playerId};
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: viewType,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: viewType,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
        );
      default:
        return const _ErrorView(message: 'Platform view not supported here');
    }
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(message,
                    style: const TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

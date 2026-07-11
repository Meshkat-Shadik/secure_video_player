import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../player_options.dart';
import '../protocol.dart';
import 'controls.dart';

/// Per-view presentation state shared between the inline player and its
/// fullscreen route: content fit and the user's manual rotation. Playback
/// state stays in [SecureVideoController]; this is pure presentation.
class PlayerUiState extends ChangeNotifier {
  PlayerUiState({BoxFit fit = BoxFit.contain}) : _fit = fit;

  static const _fitCycle = [BoxFit.contain, BoxFit.cover, BoxFit.fill];

  BoxFit _fit;
  int _extraQuarterTurns = 0;

  BoxFit get fit => _fit;

  /// User-applied rotation from the rotate button, on top of the video's own
  /// rotation metadata.
  int get extraQuarterTurns => _extraQuarterTurns;

  String get fitLabel => switch (_fit) {
        BoxFit.cover => 'Crop',
        BoxFit.fill => 'Stretch',
        _ => 'Fit',
      };

  void cycleFit() {
    _fit = _fitCycle[(_fitCycle.indexOf(_fit) + 1) % _fitCycle.length];
    notifyListeners();
  }

  void rotate() {
    _extraQuarterTurns = (_extraQuarterTurns + 1) % 4;
    notifyListeners();
  }
}

/// Renders a [SecureVideoController]'s video. Texture mode composes like any
/// widget; platformView mode embeds the native player view (with native
/// controls) — set `showControls: false` there to avoid double controls.
class SecureVideoPlayer extends StatefulWidget {
  const SecureVideoPlayer({
    super.key,
    required this.controller,
    this.showControls = true,
    this.fit = BoxFit.contain,
    this.allowFullscreen = true,
    this.fullscreenOrientations,
    this.restoreOrientationsAfterFullscreen,
    this.doubleTapSeek = const Duration(seconds: 5),
    this.onNext,
    this.onPrevious,
  });

  final SecureVideoController controller;
  final bool showControls;

  /// Initial content fit; the controls' fit button cycles it at runtime.
  final BoxFit fit;

  /// Show the fullscreen button in the Flutter controls (texture mode).
  final bool allowFullscreen;

  /// Orientations forced while fullscreen. Default (null): landscape, or
  /// portrait when the video displays taller than wide.
  final List<DeviceOrientation>? fullscreenOrientations;

  /// Orientations re-applied when the player exits fullscreen. Set this to
  /// your app's orientations (e.g. `[DeviceOrientation.portraitUp]`) if the
  /// app runs under an orientation lock — otherwise leaving fullscreen would
  /// override it. Default (null) restores all orientations (non-breaking).
  final List<DeviceOrientation>? restoreOrientationsAfterFullscreen;

  /// Seek step for the double-tap left/right gesture.
  final Duration doubleTapSeek;

  /// Playlist hooks — non-null shows next/previous buttons in the controls.
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;

  @override
  State<SecureVideoPlayer> createState() => _SecureVideoPlayerState();
}

class _SecureVideoPlayerState extends State<SecureVideoPlayer> {
  late final PlayerUiState _ui = PlayerUiState(fit: widget.fit);

  /// Tracks the CURRENT controller so the fullscreen route (a separate
  /// element tree that never rebuilds with this widget) follows playlist
  /// steps: onNext/onPrevious swap `widget.controller` and dispose the old
  /// one, which otherwise left fullscreen rendering a dead player (black).
  late final _controller = ValueNotifier(widget.controller);

  @override
  void didUpdateWidget(SecureVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.value = widget.controller;
  }

  @override
  void dispose() {
    _controller.dispose();
    _ui.dispose();
    super.dispose();
  }

  Future<void> _enterFullscreen(BuildContext context) async {
    // Decide orientation from the DISPLAY aspect (video rotation applied,
    // plus any manual rotation the user added).
    var aspect = widget.controller.value.aspectRatio;
    if (_ui.extraQuarterTurns.isOdd) aspect = 1 / aspect;
    final orientations = widget.fullscreenOrientations ??
        (aspect < 1
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
        pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
          opacity: animation,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: ValueListenableBuilder<SecureVideoController>(
              valueListenable: _controller,
              builder: (context, controller, _) => _PlayerSurface(
                // Read through State each build: playlist steps replace the
                // controller and callbacks while fullscreen stays open.
                controller: controller,
                ui: _ui,
                showControls: widget.showControls,
                isFullscreen: true,
                doubleTapSeek: widget.doubleTapSeek,
                onNext: widget.onNext,
                onPrevious: widget.onPrevious,
                onToggleFullscreen: () =>
                    Navigator.of(context, rootNavigator: true).pop(),
              ),
            ),
          ),
        ),
      ),
    );

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(
        widget.restoreOrientationsAfterFullscreen ?? DeviceOrientation.values);
  }

  @override
  Widget build(BuildContext context) {
    return _PlayerSurface(
      controller: widget.controller,
      ui: _ui,
      showControls: widget.showControls,
      isFullscreen: false,
      doubleTapSeek: widget.doubleTapSeek,
      onNext: widget.onNext,
      onPrevious: widget.onPrevious,
      onToggleFullscreen:
          widget.allowFullscreen ? () => _enterFullscreen(context) : null,
    );
  }
}

/// The actual video + controls stack, shared by inline and fullscreen.
class _PlayerSurface extends StatelessWidget {
  const _PlayerSurface({
    required this.controller,
    required this.ui,
    required this.showControls,
    required this.isFullscreen,
    required this.doubleTapSeek,
    required this.onNext,
    required this.onPrevious,
    required this.onToggleFullscreen,
  });

  final SecureVideoController controller;
  final PlayerUiState ui;
  final bool showControls;
  final bool isFullscreen;
  final Duration doubleTapSeek;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final VoidCallback? onToggleFullscreen;

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

        return ListenableBuilder(
          listenable: ui,
          builder: (context, _) {
            final Widget video;
            if (controller.renderMode == RenderMode.platformView) {
              video = _platformView(controller.playerId!);
            } else {
              video = _texture(value);
            }

            return ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  video,
                  if (value.state == SecureVideoState.buffering)
                    const Center(child: CircularProgressIndicator()),
                  // In PiP the whole app shrinks into the tiny window —
                  // controls would be unreadable noise, show bare video.
                  // PlatformView keeps native controls (gesture ownership).
                  if (showControls &&
                      !value.isPipActive &&
                      controller.renderMode == RenderMode.texture)
                    SecureVideoControls(
                      controller: controller,
                      ui: ui,
                      isFullscreen: isFullscreen,
                      doubleTapSeek: doubleTapSeek,
                      onNext: onNext,
                      onPrevious: onPrevious,
                      onToggleFullscreen: onToggleFullscreen,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Sizes the texture to the DISPLAY size and applies the platform's
  /// rotation correction (raw decoder frames aren't rotated on ImageReader /
  /// AVPlayerItemVideoOutput surfaces) plus the user's manual rotation.
  Widget _texture(SecureVideoValue value) {
    final width = value.size.width > 0 ? value.size.width : 16.0;
    final height = value.size.height > 0 ? value.size.height : 9.0;
    final correction = value.rotationCorrection % 360;

    Widget child = Texture(textureId: controller.textureId!);
    if (correction != 0) {
      final swapped = correction == 90 || correction == 270;
      // RotatedBox lays out rotated: raw-sized child ends up width×height.
      child = RotatedBox(
        quarterTurns: correction ~/ 90,
        child: SizedBox(
          width: swapped ? height : width,
          height: swapped ? width : height,
          child: child,
        ),
      );
    } else {
      child = SizedBox(width: width, height: height, child: child);
    }
    if (ui.extraQuarterTurns != 0) {
      child = RotatedBox(quarterTurns: ui.extraQuarterTurns, child: child);
    }
    return FittedBox(fit: ui.fit, clipBehavior: Clip.hardEdge, child: child);
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

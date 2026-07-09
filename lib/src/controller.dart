import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crypto_scheme.dart';
import 'errors.dart';
import 'messages.g.dart';
import 'protocol.dart';
import 'player_options.dart';

enum SecureVideoState { uninitialized, buffering, ready, completed, error }

/// A track exposed for selection (audio / subtitle / video quality).
class VideoTrack {
  const VideoTrack({
    required this.id,
    required this.type,
    required this.selected,
    this.label,
    this.language,
    this.width,
    this.height,
    this.bitrate,
  });

  final String id;
  final String type;
  final bool selected;
  final String? label;
  final String? language;
  final int? width;
  final int? height;
  final int? bitrate;

  String get displayName {
    if (label != null && label!.isNotEmpty) return label!;
    if (width != null && height != null) return '${height}p';
    if (language != null) return language!;
    return id;
  }
}

/// Immutable playback state snapshot.
@immutable
class SecureVideoValue {
  const SecureVideoValue({
    this.state = SecureVideoState.uninitialized,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.duration = Duration.zero,
    this.size = Size.zero,
    this.isPlaying = false,
    this.speed = 1.0,
    this.volume = 1.0,
    this.looping = false,
    this.isPipActive = false,
    this.error,
  });

  final SecureVideoState state;
  final Duration position;
  final Duration buffered;
  final Duration duration;
  final Size size;
  final bool isPlaying;
  final double speed;
  final double volume;
  final bool looping;
  final bool isPipActive;
  final SecureVideoException? error;

  double get aspectRatio =>
      (size.width > 0 && size.height > 0) ? size.width / size.height : 16 / 9;

  bool get isInitialized => state != SecureVideoState.uninitialized;

  SecureVideoValue copyWith({
    SecureVideoState? state,
    Duration? position,
    Duration? buffered,
    Duration? duration,
    Size? size,
    bool? isPlaying,
    double? speed,
    double? volume,
    bool? looping,
    bool? isPipActive,
    SecureVideoException? error,
  }) =>
      SecureVideoValue(
        state: state ?? this.state,
        position: position ?? this.position,
        buffered: buffered ?? this.buffered,
        duration: duration ?? this.duration,
        size: size ?? this.size,
        isPlaying: isPlaying ?? this.isPlaying,
        speed: speed ?? this.speed,
        volume: volume ?? this.volume,
        looping: looping ?? this.looping,
        isPipActive: isPipActive ?? this.isPipActive,
        error: error ?? this.error,
      );
}

/// Controls one native player instance. Multiple controllers can be live at
/// once — each maps to its own ExoPlayer/AVPlayer and event channel.
class SecureVideoController extends ValueNotifier<SecureVideoValue> {
  SecureVideoController({@visibleForTesting SecureVideoHostApi? api})
      : _api = api ?? SecureVideoHostApi(),
        super(const SecureVideoValue());

  final SecureVideoHostApi _api;

  int? _playerId;
  int? _textureId;
  RenderMode _renderMode = RenderMode.texture;
  StreamSubscription<dynamic>? _eventSub;
  Completer<void>? _readyCompleter;
  Future<CreateResponse>? _pendingCreate;
  bool _disposed = false;

  int? get playerId => _playerId;
  int? get textureId => _textureId;
  RenderMode get renderMode => _renderMode;

  /// Creates the native player and completes when it is ready to render.
  Future<void> initialize({
    required VideoSource source,
    CryptoScheme scheme = const CryptoScheme.none(),
    PlayerOptions options = const PlayerOptions(),
  }) async {
    _checkDisposed();
    if (_playerId != null) {
      throw StateError('Controller already initialized');
    }
    _renderMode = options.renderMode;
    _readyCompleter = Completer<void>();

    final CreateResponse response;
    try {
      _pendingCreate = _api.create(CreateRequest(
        sourceType: source.type,
        source: source.value,
        schemeType: scheme.type,
        schemeParams: scheme.params,
        renderMode: options.renderMode.name,
        autoPlay: options.autoPlay,
        looping: options.looping,
        volume: options.volume,
        startPositionMs: options.startPosition.inMilliseconds,
        minBufferMs: options.buffer.minBufferMs,
        maxBufferMs: options.buffer.maxBufferMs,
        bufferForPlaybackMs: options.buffer.bufferForPlaybackMs,
      ));
      response = await _pendingCreate!;
    } on PlatformException catch (e) {
      _pendingCreate = null;
      throw SecureVideoException.fromPlatform(e);
    }
    _pendingCreate = null;

    // Widget popped while create() was in flight — release the native
    // player immediately or it keeps decoding forever (issue #1).
    if (_disposed) {
      _readyCompleter?.future.ignore();
      try {
        await _api.dispose(response.playerId);
      } on PlatformException {
        // Already gone natively.
      }
      throw SecureVideoException(
          SecureVideoErrorCode.disposed, 'Controller was disposed');
    }

    _playerId = response.playerId;
    _textureId = response.textureId;
    value = value.copyWith(
      state: SecureVideoState.buffering,
      looping: options.looping,
      volume: options.volume,
    );

    _eventSub = EventChannel(SvpChannels.playerEvents(response.playerId))
        .receiveBroadcastStream()
        .listen(_onEvent, onError: _onEventError);

    await _readyCompleter!.future;
  }

  void _onEvent(dynamic event) {
    final m = (event as Map).cast<String, Object?>();
    switch (m[SvpEvents.key]) {
      case SvpEvents.initialized:
        value = value.copyWith(
          state: SecureVideoState.ready,
          duration: Duration(milliseconds: (m[SvpEvents.keyDuration] as num).toInt()),
          size: Size((m[SvpEvents.keyWidth] as num?)?.toDouble() ?? 0,
              (m[SvpEvents.keyHeight] as num?)?.toDouble() ?? 0),
        );
        if (!(_readyCompleter?.isCompleted ?? true)) {
          _readyCompleter!.complete();
        }
      case SvpEvents.buffering:
        value = value.copyWith(state: SecureVideoState.buffering);
      case SvpEvents.ready:
        if (value.state != SecureVideoState.uninitialized) {
          value = value.copyWith(state: SecureVideoState.ready);
        }
      case SvpEvents.position:
        value = value.copyWith(
          position: Duration(milliseconds: (m[SvpEvents.keyPosition] as num).toInt()),
          buffered:
              Duration(milliseconds: (m[SvpEvents.keyBuffered] as num?)?.toInt() ?? 0),
        );
      case SvpEvents.isPlayingChanged:
        value = value.copyWith(isPlaying: m[SvpEvents.keyIsPlaying] == true);
      case SvpEvents.videoSize:
        value = value.copyWith(
            size: Size((m[SvpEvents.keyWidth] as num).toDouble(),
                (m[SvpEvents.keyHeight] as num).toDouble()));
      case SvpEvents.completed:
        value = value.copyWith(
            state: SecureVideoState.completed, isPlaying: false);
      case SvpEvents.pipChanged:
        value = value.copyWith(isPipActive: m[SvpEvents.keyActive] == true);
      case SvpEvents.error:
        final error = SecureVideoException(
            SecureVideoErrorCode.fromWire(m[SvpEvents.keyCode] as String?),
            (m[SvpEvents.keyMessage] as String?) ?? 'Unknown player error');
        value = value.copyWith(state: SecureVideoState.error, error: error);
        if (!(_readyCompleter?.isCompleted ?? true)) {
          _readyCompleter!.completeError(error);
        }
    }
  }

  void _onEventError(Object e) {
    final error = e is PlatformException
        ? SecureVideoException.fromPlatform(e)
        : SecureVideoException(SecureVideoErrorCode.unknown, e.toString());
    value = value.copyWith(state: SecureVideoState.error, error: error);
    if (!(_readyCompleter?.isCompleted ?? true)) {
      _readyCompleter!.completeError(error);
    }
  }

  Future<void> play() => _call((id) => _api.play(id));

  Future<void> pause() => _call((id) => _api.pause(id));

  Future<void> seekTo(Duration position) =>
      _call((id) => _api.seekTo(id, position.inMilliseconds));

  Future<void> setSpeed(double speed) async {
    await _call((id) => _api.setSpeed(id, speed));
    value = value.copyWith(speed: speed);
  }

  Future<void> setLooping(bool looping) async {
    await _call((id) => _api.setLooping(id, looping));
    value = value.copyWith(looping: looping);
  }

  Future<void> setVolume(double volume) async {
    await _call((id) => _api.setVolume(id, volume.clamp(0.0, 1.0)));
    value = value.copyWith(volume: volume.clamp(0.0, 1.0));
  }

  /// Fresh position straight from the native player (events update ~4x/s).
  Future<Duration> position() async {
    final ms = await _call((id) => _api.getPosition(id));
    return Duration(milliseconds: ms);
  }

  Future<List<VideoTrack>> getTracks(String type) async {
    final tracks = await _call((id) => _api.getTracks(id, type));
    return tracks
        .map((t) => VideoTrack(
              id: t.id,
              type: t.type,
              selected: t.selected,
              label: t.label,
              language: t.language,
              width: t.width,
              height: t.height,
              bitrate: t.bitrate,
            ))
        .toList();
  }

  /// [trackId] null = disable (subtitles off / auto quality).
  Future<void> selectTrack(String type, String? trackId) =>
      _call((id) => _api.selectTrack(id, type, trackId));

  Future<void> addExternalSubtitle(String path,
          {String mimeType = 'text/vtt', String? language}) =>
      _call((id) => _api.addExternalSubtitle(id, path, mimeType, language));

  Future<bool> enterPictureInPicture() =>
      _call((id) => _api.enterPictureInPicture(id));

  Future<void> setBackgroundPlayback(bool enabled) =>
      _call((id) => _api.setBackgroundPlayback(id, enabled));

  Future<T> _call<T>(Future<T> Function(int playerId) fn) async {
    _checkDisposed();
    final id = _playerId;
    if (id == null) {
      throw SecureVideoException(
          SecureVideoErrorCode.unknown, 'Controller not initialized');
    }
    try {
      return await fn(id);
    } on PlatformException catch (e) {
      throw SecureVideoException.fromPlatform(e);
    }
  }

  void _checkDisposed() {
    if (_disposed) {
      throw SecureVideoException(
          SecureVideoErrorCode.disposed, 'Controller is disposed');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Unblock anyone still awaiting initialize().
    if (!(_readyCompleter?.isCompleted ?? true)) {
      _readyCompleter!.future.ignore();
      _readyCompleter!.completeError(SecureVideoException(
          SecureVideoErrorCode.disposed, 'Controller was disposed'));
    }
    await _eventSub?.cancel();
    final id = _playerId;
    _playerId = null;
    if (id != null) {
      try {
        await _api.dispose(id);
      } on PlatformException {
        // Native side already gone — nothing to release.
      }
    }
    // If create() is still in flight, the initialize() continuation sees
    // _disposed and releases the native player itself.
    super.dispose();
  }
}

/// Window-level screen-capture protection (Android FLAG_SECURE; iOS best
/// effort). Global, not per-player — it protects the whole window.
Future<void> setScreenCaptureProtection(bool enabled) =>
    SecureVideoHostApi().setSecureFlag(enabled);

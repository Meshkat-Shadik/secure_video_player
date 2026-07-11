import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crypto_scheme.dart';
import 'errors.dart';
import 'messages.g.dart';
import 'progress_triggers.dart';
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
    this.rotationCorrection = 0,
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

  /// Display size — rotation already applied (portrait video → portrait size).
  final Size size;

  /// Degrees (0/90/180/270) the raw texture must be rotated by to appear
  /// upright. Non-zero when the platform surface can't apply the video
  /// track's rotation metadata itself; [SecureVideoPlayer] handles it.
  final int rotationCorrection;
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
    int? rotationCorrection,
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
        rotationCorrection: rotationCorrection ?? this.rotationCorrection,
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
        super(const SecureVideoValue()) {
    addListener(_updateWakelock);
  }

  final SecureVideoHostApi _api;

  int? _playerId;
  int? _textureId;
  RenderMode _renderMode = RenderMode.texture;
  StreamSubscription<dynamic>? _eventSub;
  Completer<void>? _readyCompleter;
  Future<CreateResponse>? _pendingCreate;
  bool _disposed = false;

  final ProgressTriggerScheduler _triggers = ProgressTriggerScheduler();

  Timer? _sleepTimer;
  DateTime? _sleepDeadline;

  /// Number of live controllers currently asking to keep the screen awake.
  /// The native flag flips on the 0→1 acquire and off on the 1→0 release, so
  /// two players never fight over it (last-off wins).
  static int _wakeRefCount = 0;
  bool _wakeHeld = false;
  bool _keepAwakeOption = false;

  /// null = automatic (follow [_keepAwakeOption] + isPlaying); non-null pins it.
  bool? _wakeOverride;

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
    _keepAwakeOption = options.keepScreenAwakeWhilePlaying;
    _readyCompleter = Completer<void>();
    // Anchor the trigger cursor at the resume position so triggers before it
    // don't fire on the first position event.
    _triggers.onSeek(options.startPosition.inMilliseconds);

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

    // Apply create-time platform config now the native player is live.
    if (options.allowBackgroundPlayback) {
      await setBackgroundPlayback(true);
    }
    if (options.mediaControls.enabled) {
      await updateMediaControls(options.mediaControls);
    }
  }

  void _onEvent(dynamic event) {
    final m = (event as Map).cast<String, Object?>();
    switch (m[SvpEvents.key]) {
      case SvpEvents.initialized:
        final durationMs = (m[SvpEvents.keyDuration] as num).toInt();
        _triggers.setDuration(durationMs);
        value = value.copyWith(
          state: SecureVideoState.ready,
          duration: Duration(milliseconds: durationMs),
          size: Size((m[SvpEvents.keyWidth] as num?)?.toDouble() ?? 0,
              (m[SvpEvents.keyHeight] as num?)?.toDouble() ?? 0),
          rotationCorrection:
              (m[SvpEvents.keyRotationCorrection] as num?)?.toInt() ?? 0,
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
        final positionMs = (m[SvpEvents.keyPosition] as num).toInt();
        _triggers.onPosition(positionMs);
        value = value.copyWith(
          position: Duration(milliseconds: positionMs),
          buffered:
              Duration(milliseconds: (m[SvpEvents.keyBuffered] as num?)?.toInt() ?? 0),
        );
      case SvpEvents.isPlayingChanged:
        value = value.copyWith(isPlaying: m[SvpEvents.keyIsPlaying] == true);
      case SvpEvents.videoSize:
        value = value.copyWith(
            size: Size((m[SvpEvents.keyWidth] as num).toDouble(),
                (m[SvpEvents.keyHeight] as num).toDouble()),
            rotationCorrection:
                (m[SvpEvents.keyRotationCorrection] as num?)?.toInt() ?? 0);
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

  Future<void> seekTo(Duration position) {
    // Reposition the trigger cursor first so a seek is a jump, not a
    // playthrough (no intermediate triggers fire).
    _triggers.onSeek(position.inMilliseconds);
    return _call((id) => _api.seekTo(id, position.inMilliseconds));
  }

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

  /// Shows/updates (or tears down, when [MediaControlsOptions.enabled] is
  /// false) the system media controls for this player.
  Future<void> updateMediaControls(MediaControlsOptions controls) =>
      _call((id) => _api.configureMediaControls(
            id,
            MediaControlsConfig(
              enabled: controls.enabled,
              title: controls.title,
              artist: controls.artist,
              artworkPath: controls.artworkPath,
            ),
          ));

  /// Registers a callback that fires when playback crosses [t]'s point.
  /// Returns a handle to cancel it. See [ProgressTrigger].
  TriggerHandle addProgressTrigger(ProgressTrigger t) {
    _checkDisposed();
    return _triggers.add(t);
  }

  /// Pauses playback after [d]. [onFired] runs after the pause. Replaces any
  /// existing sleep timer. Canceled automatically on dispose.
  void setSleepTimer(Duration d, {VoidCallback? onFired}) {
    _checkDisposed();
    cancelSleepTimer();
    _sleepDeadline = DateTime.now().add(d);
    _sleepTimer = Timer(d, () {
      _sleepTimer = null;
      _sleepDeadline = null;
      if (_disposed) return;
      pause().catchError((Object _) {});
      onFired?.call();
    });
  }

  /// Cancels a pending sleep timer, if any.
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
  }

  /// Time left on the sleep timer, or null when none is set.
  Duration? get sleepTimerRemaining {
    final deadline = _sleepDeadline;
    if (deadline == null) return null;
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Manual override for the keep-screen-awake behavior: `true` forces the
  /// screen awake, `false` forces it to sleep, `null` returns to automatic
  /// (awake while playing when the option is enabled).
  void setKeepScreenAwake(bool? enabled) {
    _checkDisposed();
    _wakeOverride = enabled;
    _updateWakelock();
  }

  bool get _wantWake =>
      _wakeOverride ?? (_keepAwakeOption && value.isPlaying);

  void _updateWakelock() {
    if (_disposed) return;
    final want = _wantWake;
    if (want == _wakeHeld) return;
    _wakeHeld = want;
    if (want) {
      if (++_wakeRefCount == 1) _pushWakelock(true);
    } else {
      if (--_wakeRefCount == 0) _pushWakelock(false);
    }
  }

  void _pushWakelock(bool enabled) {
    _api.setKeepScreenAwake(enabled).catchError((Object _) {});
  }

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
    removeListener(_updateWakelock);
    // Release the wakelock ref this controller was holding, if any.
    if (_wakeHeld) {
      _wakeHeld = false;
      if (--_wakeRefCount == 0) _pushWakelock(false);
    }
    cancelSleepTimer();
    _triggers.dispose();
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

/// Window brightness 0.0–1.0. Pass -1 to restore the system default
/// (Android window override cleared; on iOS capture the old value with
/// [getScreenBrightness] first and set it back). Used by the fullscreen
/// left-edge swipe gesture; also callable directly.
Future<void> setScreenBrightness(double brightness) =>
    SecureVideoHostApi().setScreenBrightness(brightness);

/// Current window brightness 0.0–1.0; -1 means "following system default".
Future<double> getScreenBrightness() =>
    SecureVideoHostApi().getScreenBrightness();

/// Container + per-stream metadata for a (possibly encrypted) media file —
/// codec, profile, resolution, frame rate, bitrate, sample rate, channels,
/// language. Decrypts through the same native CipherAdapter as playback.
Future<MediaInfo> getMediaInfo(String path,
    {CryptoScheme scheme = const CryptoScheme.none()}) async {
  try {
    return await SecureVideoHostApi()
        .getMediaInfo(path, scheme.type, scheme.params);
  } on PlatformException catch (e) {
    throw SecureVideoException.fromPlatform(e);
  }
}

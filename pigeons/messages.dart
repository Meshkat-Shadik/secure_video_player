import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  kotlinOut:
      'android/src/main/kotlin/com/hulkenstein/secure_video_player/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.hulkenstein.secure_video_player'),
  swiftOut: 'ios/Classes/Messages.g.swift',
  dartPackageName: 'secure_video_player',
))
class CreateRequest {
  CreateRequest({
    required this.sourceType,
    required this.source,
    required this.schemeType,
    required this.schemeParams,
    required this.renderMode,
    required this.autoPlay,
    required this.looping,
    required this.volume,
    required this.startPositionMs,
    required this.minBufferMs,
    required this.maxBufferMs,
    required this.bufferForPlaybackMs,
  });

  /// 'file' | 'asset' | 'url'
  String sourceType;
  String source;

  /// 'none' | 'xorLegacy' | 'aesCtr' | 'clearKey' | custom adapter name
  String schemeType;
  Map<String?, Object?> schemeParams;

  /// 'texture' | 'platformView'
  String renderMode;
  bool autoPlay;
  bool looping;
  double volume;
  int startPositionMs;
  int minBufferMs;
  int maxBufferMs;
  int bufferForPlaybackMs;
}

class CreateResponse {
  CreateResponse({required this.playerId, this.textureId});
  int playerId;

  /// Null when renderMode == 'platformView'.
  int? textureId;
}

class TrackInfo {
  TrackInfo({
    required this.id,
    required this.type,
    required this.selected,
    this.label,
    this.language,
    this.width,
    this.height,
    this.bitrate,
  });
  String id;

  /// 'audio' | 'subtitle' | 'video'
  String type;
  bool selected;
  String? label;
  String? language;
  int? width;
  int? height;
  int? bitrate;
}

/// One elementary stream inside a media container.
class MediaStreamInfo {
  MediaStreamInfo({
    required this.type,
    this.codec,
    this.profile,
    this.width,
    this.height,
    this.frameRate,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.language,
  });

  /// 'video' | 'audio' | 'subtitle' | 'unknown'
  String type;
  String? codec;
  String? profile;
  int? width;
  int? height;
  double? frameRate;
  int? bitrate;
  int? sampleRate;
  int? channels;
  String? language;
}

/// Container-level metadata + per-stream details (MX-Player-style info).
class MediaInfo {
  MediaInfo({
    required this.durationMs,
    this.container,
    this.rotation,
    this.bitrate,
    required this.streams,
  });

  int durationMs;

  /// e.g. 'video/mp4' (Android MIME) or 'mp4' (iOS best effort).
  String? container;

  /// Display rotation in degrees (0/90/180/270) from the video track.
  int? rotation;

  /// Overall bitrate when the container reports one.
  int? bitrate;
  List<MediaStreamInfo?> streams;
}

/// System media-controls surface (Android media notification via
/// MediaSessionService, iOS Now Playing + remote commands).
class MediaControlsConfig {
  MediaControlsConfig({
    required this.enabled,
    this.title,
    this.artist,
    this.artworkPath,
  });

  bool enabled;
  String? title;
  String? artist;

  /// Local file path to artwork image, optional.
  String? artworkPath;
}

@HostApi()
abstract class SecureVideoHostApi {
  CreateResponse create(CreateRequest request);
  void dispose(int playerId);
  void play(int playerId);
  void pause(int playerId);
  void seekTo(int playerId, int positionMs);
  void setSpeed(int playerId, double speed);
  void setLooping(int playerId, bool looping);
  void setVolume(int playerId, double volume);
  int getPosition(int playerId);
  List<TrackInfo> getTracks(int playerId, String type);

  /// trackId == null disables the track type (subtitles off / auto quality).
  void selectTrack(int playerId, String type, String? trackId);
  void addExternalSubtitle(
      int playerId, String path, String mimeType, String? language);
  bool enterPictureInPicture(int playerId);
  void setBackgroundPlayback(int playerId, bool enabled);

  /// Window-level capture protection (FLAG_SECURE / iOS best effort).
  void setSecureFlag(bool enabled);

  /// Keeps the screen on while true (FLAG_KEEP_SCREEN_ON / isIdleTimerDisabled).
  /// Global window/app level — callers ref-count on the Dart side.
  void setKeepScreenAwake(bool enabled);

  /// Shows/updates (enabled=true) or tears down (enabled=false) system media
  /// controls for the player: Android media notification, iOS Now Playing.
  void configureMediaControls(int playerId, MediaControlsConfig config);

  /// Probes a (possibly encrypted) media file: container, duration, and
  /// per-stream codec/profile/resolution/fps/bitrate/sampleRate/channels.
  /// Decryption happens through the same CipherAdapter as playback.
  ///
  /// Runs on a background task queue so the blocking probe never stalls the
  /// platform thread (ANR on slow storage / native schemes).
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  MediaInfo getMediaInfo(
      String path, String schemeType, Map<String?, Object?> schemeParams);

  /// Window screen brightness 0.0–1.0; pass -1 to restore system default.
  /// Android: WindowManager.LayoutParams.screenBrightness.
  /// iOS: UIScreen.main.brightness (persists — callers should restore).
  void setScreenBrightness(double brightness);

  /// Current window brightness 0.0–1.0 (-1 = following system default).
  double getScreenBrightness();

  /// Starts encrypt (encrypt=true) or decrypt file transform.
  /// Returns operationId; progress on EventChannel 'secure_video_player/crypto_events'.
  String startCrypto(String inputPath, String outputPath, String schemeType,
      Map<String?, Object?> schemeParams, bool encrypt);
  void cancelCrypto(String operationId);
}

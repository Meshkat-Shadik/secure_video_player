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

  /// Starts encrypt (encrypt=true) or decrypt file transform.
  /// Returns operationId; progress on EventChannel 'secure_video_player/crypto_events'.
  String startCrypto(String inputPath, String outputPath, String schemeType,
      Map<String?, Object?> schemeParams, bool encrypt);
  void cancelCrypto(String operationId);
}

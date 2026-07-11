/// Wire protocol shared with the native sides. Must stay in sync with
/// `SvpProtocol.kt` (Android) and `SvpProtocol.swift` (iOS).
abstract final class SvpChannels {
  static const String cryptoEvents = 'secure_video_player/crypto_events';
  static const String platformViewType = 'secure_video_player/platform_view';
  static const String _playerEventsPrefix = 'secure_video_player/events_';

  static String playerEvents(int playerId) => '$_playerEventsPrefix$playerId';
}

/// Player event names + payload keys arriving on the per-player channel.
abstract final class SvpEvents {
  static const String key = 'event';

  static const String initialized = 'initialized';
  static const String buffering = 'buffering';
  static const String ready = 'ready';
  static const String position = 'position';
  static const String isPlayingChanged = 'isPlayingChanged';
  static const String videoSize = 'videoSize';
  static const String completed = 'completed';
  static const String pipChanged = 'pipChanged';
  static const String error = 'error';

  static const String keyDuration = 'duration';
  static const String keyWidth = 'width';
  static const String keyHeight = 'height';
  static const String keyRotationCorrection = 'rotationCorrection';
  static const String keyPosition = 'position';
  static const String keyBuffered = 'buffered';
  static const String keyIsPlaying = 'isPlaying';
  static const String keyActive = 'active';
  static const String keyCode = 'code';
  static const String keyMessage = 'message';
}

/// Crypto progress payload keys on [SvpChannels.cryptoEvents].
abstract final class SvpCryptoEvents {
  static const String keyOperationId = 'operationId';
  static const String keyBytesProcessed = 'bytesProcessed';
  static const String keyTotalBytes = 'totalBytes';
  static const String keyDone = 'done';
  static const String keyError = 'error';
  static const String keyErrorCode = 'errorCode';
}

/// Track type identifiers for getTracks/selectTrack.
abstract final class SvpTrackTypes {
  static const String audio = 'audio';
  static const String subtitle = 'subtitle';
  static const String video = 'video';
}

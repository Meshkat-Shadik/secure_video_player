/// Where the video bytes come from.
class VideoSource {
  const VideoSource._(this.type, this.value);

  /// Local file path (the encrypted file for non-none schemes).
  const VideoSource.file(String path) : this._('file', path);

  /// Flutter asset key (copied to a temp file natively before playback).
  const VideoSource.asset(String key) : this._('asset', key);

  /// Network URL — only meaningful with [CryptoScheme.none] or clearKey.
  const VideoSource.url(String url) : this._('url', url);

  /// Android `content://` URI (e.g. a MediaStore video). Decrypts on the fly
  /// like [VideoSource.file], but reads through the ContentResolver — use it
  /// to play an encrypted gallery file edited in place, with no plaintext
  /// copy on disk. Android only.
  const VideoSource.contentUri(String uri) : this._('contentUri', uri);

  final String type;
  final String value;
}

enum RenderMode {
  /// Flutter Texture; controls drawn by Flutter. Composable, multi-player.
  texture,

  /// Native PlayerView / AVPlayerViewController with native controls.
  platformView,
}

/// Media3 LoadControl / AVPlayer buffer tuning.
class BufferConfig {
  const BufferConfig({
    this.minBufferMs = 15000,
    this.maxBufferMs = 30000,
    this.bufferForPlaybackMs = 2500,
  });

  /// Tight buffers for 1 GB RAM devices.
  const BufferConfig.lowRam()
      : this(minBufferMs: 8000, maxBufferMs: 15000, bufferForPlaybackMs: 1500);

  final int minBufferMs;
  final int maxBufferMs;
  final int bufferForPlaybackMs;
}

/// System media-controls surface config — Android media notification, iOS Now
/// Playing + remote commands. Disabled by default. When [enabled], the
/// controller drives the native surface via `configureMediaControls`.
class MediaControlsOptions {
  const MediaControlsOptions({
    this.enabled = false,
    this.title,
    this.artist,
    this.artworkPath,
  });

  final bool enabled;
  final String? title;
  final String? artist;

  /// Local file path to artwork image, optional.
  final String? artworkPath;
}

class PlayerOptions {
  const PlayerOptions({
    this.renderMode = RenderMode.texture,
    this.autoPlay = false,
    this.looping = false,
    this.volume = 1.0,
    this.startPosition = Duration.zero,
    this.buffer = const BufferConfig(),
    this.keepScreenAwakeWhilePlaying = true,
    this.mediaControls = const MediaControlsOptions(),
    this.allowBackgroundPlayback = false,
  });

  final RenderMode renderMode;
  final bool autoPlay;
  final bool looping;
  final double volume;
  final Duration startPosition;
  final BufferConfig buffer;

  /// Hold the screen awake while this player is playing. Ref-counted across
  /// controllers so multiple players don't fight — the screen stays awake
  /// while any player wants it, and only sleeps once none do.
  final bool keepScreenAwakeWhilePlaying;

  /// System media controls (notification / now-playing). Disabled by default.
  final MediaControlsOptions mediaControls;

  /// Keep decoding audio when the app is backgrounded. Requires host-app
  /// setup (Android foreground service, iOS `UIBackgroundModes: audio`).
  final bool allowBackgroundPlayback;
}

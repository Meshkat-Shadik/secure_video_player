/// Where the video bytes come from.
class VideoSource {
  const VideoSource._(this.type, this.value);

  /// Local file path (the encrypted file for non-none schemes).
  const VideoSource.file(String path) : this._('file', path);

  /// Flutter asset key (copied to a temp file natively before playback).
  const VideoSource.asset(String key) : this._('asset', key);

  /// Network URL — only meaningful with [CryptoScheme.none] or clearKey.
  const VideoSource.url(String url) : this._('url', url);

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

class PlayerOptions {
  const PlayerOptions({
    this.renderMode = RenderMode.texture,
    this.autoPlay = false,
    this.looping = false,
    this.volume = 1.0,
    this.startPosition = Duration.zero,
    this.buffer = const BufferConfig(),
  });

  final RenderMode renderMode;
  final bool autoPlay;
  final bool looping;
  final double volume;
  final Duration startPosition;
  final BufferConfig buffer;
}

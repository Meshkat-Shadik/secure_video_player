import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'secure_video_player_method_channel.dart';

abstract class SecureVideoPlayerPlatform extends PlatformInterface {
  /// Constructs a SecureVideoPlayerPlatform.
  SecureVideoPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static SecureVideoPlayerPlatform _instance = MethodChannelSecureVideoPlayer();

  /// The default instance of [SecureVideoPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelSecureVideoPlayer].
  static SecureVideoPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [SecureVideoPlayerPlatform] when
  /// they register themselves.
  static set instance(SecureVideoPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}

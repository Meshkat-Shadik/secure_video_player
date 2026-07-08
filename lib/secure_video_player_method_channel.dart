import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'secure_video_player_platform_interface.dart';

/// An implementation of [SecureVideoPlayerPlatform] that uses method channels.
class MethodChannelSecureVideoPlayer extends SecureVideoPlayerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('secure_video_player');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}

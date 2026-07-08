
import 'secure_video_player_platform_interface.dart';

class SecureVideoPlayer {
  Future<String?> getPlatformVersion() {
    return SecureVideoPlayerPlatform.instance.getPlatformVersion();
  }
}

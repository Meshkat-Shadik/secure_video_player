import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';
import 'package:secure_video_player/secure_video_player_platform_interface.dart';
import 'package:secure_video_player/secure_video_player_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockSecureVideoPlayerPlatform
    with MockPlatformInterfaceMixin
    implements SecureVideoPlayerPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final SecureVideoPlayerPlatform initialPlatform = SecureVideoPlayerPlatform.instance;

  test('$MethodChannelSecureVideoPlayer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelSecureVideoPlayer>());
  });

  test('getPlatformVersion', () async {
    SecureVideoPlayer secureVideoPlayerPlugin = SecureVideoPlayer();
    MockSecureVideoPlayerPlatform fakePlatform = MockSecureVideoPlayerPlatform();
    SecureVideoPlayerPlatform.instance = fakePlatform;

    expect(await secureVideoPlayerPlugin.getPlatformVersion(), '42');
  });
}

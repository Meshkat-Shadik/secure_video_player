import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';
import 'package:secure_video_player/src/messages.g.dart';

/// Records host-API calls instead of hitting a platform channel.
class FakeHostApi extends SecureVideoHostApi {
  final calls = <String>[];
  Object? createError;

  @override
  Future<CreateResponse> create(CreateRequest request) async {
    calls.add('create:${request.schemeType}:${request.renderMode}');
    if (createError != null) throw createError!;
    return CreateResponse(playerId: 7, textureId: 42);
  }

  @override
  Future<void> dispose(int playerId) async => calls.add('dispose:$playerId');

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> seekTo(int playerId, int positionMs) async =>
      calls.add('seekTo:$positionMs');

  @override
  Future<void> setSpeed(int playerId, double speed) async =>
      calls.add('setSpeed:$speed');

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      calls.add('setLooping:$looping');

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      calls.add('setVolume:$volume');

  @override
  Future<int> getPosition(int playerId) async => 1234;

  @override
  Future<List<TrackInfo>> getTracks(int playerId, String type) async =>
      [TrackInfo(id: '0:0', type: type, selected: true, label: 'English')];

  @override
  Future<void> selectTrack(int playerId, String type, String? trackId) async =>
      calls.add('selectTrack:$type:$trackId');

  @override
  Future<void> addExternalSubtitle(
          int playerId, String path, String mimeType, String? language) async =>
      calls.add('subtitle:$path');

  @override
  Future<bool> enterPictureInPicture(int playerId) async => true;

  @override
  Future<void> setBackgroundPlayback(int playerId, bool enabled) async =>
      calls.add('background:$enabled');

  @override
  Future<void> setSecureFlag(bool enabled) async {}

  @override
  Future<String> startCrypto(String inputPath, String outputPath,
          String schemeType, Map<String?, Object?> schemeParams, bool encrypt) async =>
      'op1';

  @override
  Future<void> cancelCrypto(String operationId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHostApi api;
  late SecureVideoController controller;

  void mockEvents(List<Map<String, Object?>> events) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('secure_video_player/events_7'),
      MockStreamHandler.inline(onListen: (args, sink) {
        for (final e in events) {
          sink.success(e);
        }
      }),
    );
  }

  setUp(() {
    api = FakeHostApi();
    controller = SecureVideoController(api: api);
  });

  test('initialize completes on initialized event and captures metadata',
      () async {
    mockEvents([
      {'event': 'initialized', 'duration': 30000, 'width': 640, 'height': 360},
    ]);
    await controller.initialize(
      source: const VideoSource.file('/x.enc'),
      scheme: const CryptoScheme.xorLegacy(),
    );
    expect(controller.playerId, 7);
    expect(controller.textureId, 42);
    expect(controller.value.state, SecureVideoState.ready);
    expect(controller.value.duration, const Duration(seconds: 30));
    expect(controller.value.size.width, 640);
    expect(api.calls.first, 'create:xorLegacy:texture');
  });

  test('initialize surfaces typed error from create', () async {
    api.createError =
        PlatformException(code: 'fileNotFound', message: 'nope');
    expect(
      () => controller.initialize(source: const VideoSource.file('/x')),
      throwsA(isA<SecureVideoException>().having(
          (e) => e.code, 'code', SecureVideoErrorCode.fileNotFound)),
    );
  });

  test('initialize fails when native reports error event', () async {
    mockEvents([
      {'event': 'error', 'code': 'corruptStream', 'message': 'bad bytes'},
    ]);
    await expectLater(
      controller.initialize(
          source: const VideoSource.file('/x.enc'),
          scheme: const CryptoScheme.xorLegacy()),
      throwsA(isA<SecureVideoException>().having(
          (e) => e.code, 'code', SecureVideoErrorCode.corruptStream)),
    );
    expect(controller.value.state, SecureVideoState.error);
  });

  test('controls forward to host api and update value', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 30000, 'width': 640, 'height': 360},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    await controller.play();
    await controller.pause();
    await controller.seekTo(const Duration(seconds: 5));
    await controller.setSpeed(2.0);
    await controller.setVolume(0.5);
    await controller.setLooping(true);
    expect(
        api.calls,
        containsAllInOrder(
            ['play', 'pause', 'seekTo:5000', 'setSpeed:2.0', 'setVolume:0.5', 'setLooping:true']));
    expect(controller.value.speed, 2.0);
    expect(controller.value.volume, 0.5);
    expect(controller.value.looping, true);
  });

  test('position/isPlaying/completed events update value', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 30000, 'width': 640, 'height': 360},
      {'event': 'isPlayingChanged', 'isPlaying': true},
      {'event': 'position', 'position': 1500, 'buffered': 4000},
      {'event': 'completed'},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.value.position, const Duration(milliseconds: 1500));
    expect(controller.value.buffered, const Duration(seconds: 4));
    expect(controller.value.state, SecureVideoState.completed);
    expect(controller.value.isPlaying, false);
  });

  test('methods throw after dispose', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    await controller.dispose();
    expect(api.calls, contains('dispose:7'));
    expect(
      () => controller.play(),
      throwsA(isA<SecureVideoException>().having(
          (e) => e.code, 'code', SecureVideoErrorCode.disposed)),
    );
  });

  test('getTracks maps TrackInfo to VideoTrack', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    final tracks = await controller.getTracks('audio');
    expect(tracks, hasLength(1));
    expect(tracks.first.id, '0:0');
    expect(tracks.first.displayName, 'English');
  });
}

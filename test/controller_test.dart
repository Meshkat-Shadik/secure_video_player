import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';
import 'package:secure_video_player/src/messages.g.dart';

/// Records host-API calls instead of hitting a platform channel.
class FakeHostApi extends SecureVideoHostApi {
  FakeHostApi({this.playerId = 7});

  final int playerId;
  final calls = <String>[];
  final keepAwake = <bool>[];
  Object? createError;

  @override
  Future<CreateResponse> create(CreateRequest request) async {
    calls.add(
        'create:${request.schemeType}:${request.renderMode}:${request.sourceType}');
    if (createError != null) throw createError!;
    return CreateResponse(playerId: playerId, textureId: 42);
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
  Future<void> setKeepScreenAwake(bool enabled) async => keepAwake.add(enabled);

  @override
  Future<void> configureMediaControls(
          int playerId, MediaControlsConfig config) async =>
      calls.add('mediaControls:$playerId:${config.enabled}:${config.title}');

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

  void mockEvents(List<Map<String, Object?>> events, {int playerId = 7}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      EventChannel('secure_video_player/events_$playerId'),
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

  tearDown(() async {
    // Keep the static wakelock ref-count balanced between tests.
    await controller.dispose();
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
    expect(controller.value.rotationCorrection, 0);
    expect(api.calls.first, 'create:xorLegacy:texture:file');
  });

  test('content:// source flows through as sourceType contentUri', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 8, 'height': 8},
    ]);
    await controller.initialize(
      source: const VideoSource.contentUri(
          'content://media/external/video/media/42'),
      scheme: const CryptoScheme.xorLegacy(),
    );
    expect(api.calls.first, 'create:xorLegacy:texture:contentUri');
  });

  test('rotationCorrection flows from initialized and videoSize events',
      () async {
    mockEvents([
      // Portrait phone video: display size 1080x1920, raw frames rotated 90°.
      {
        'event': 'initialized',
        'duration': 5000,
        'width': 1080,
        'height': 1920,
        'rotationCorrection': 90,
      },
      {
        'event': 'videoSize',
        'width': 1920,
        'height': 1080,
        'rotationCorrection': 0,
      },
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    await pumpEventQueue();
    // Last event wins; both parsed.
    expect(controller.value.size, const Size(1920, 1080));
    expect(controller.value.rotationCorrection, 0);
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

  test('create applies background playback and media controls from options',
      () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(
      source: const VideoSource.file('/x.enc'),
      options: const PlayerOptions(
        allowBackgroundPlayback: true,
        mediaControls: MediaControlsOptions(enabled: true, title: 'Movie'),
      ),
    );
    expect(api.calls, contains('background:true'));
    expect(api.calls, contains('mediaControls:7:true:Movie'));
  });

  test('default options do not touch background/media controls', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    expect(api.calls.where((c) => c.startsWith('background:')), isEmpty);
    expect(api.calls.where((c) => c.startsWith('mediaControls:')), isEmpty);
  });

  test('updateMediaControls forwards config to host', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    await controller.updateMediaControls(
        const MediaControlsOptions(enabled: true, title: 'X'));
    expect(api.calls, contains('mediaControls:7:true:X'));
  });

  test('progress trigger fires from position events', () async {
    var count = 0;
    controller.addProgressTrigger(
        ProgressTrigger.at(const Duration(seconds: 1), () => count++));
    mockEvents([
      {'event': 'initialized', 'duration': 10000, 'width': 1, 'height': 1},
      {'event': 'position', 'position': 500, 'buffered': 500},
      {'event': 'position', 'position': 1500, 'buffered': 1500},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    await pumpEventQueue();
    expect(count, 1);
  });

  test('sleep timer pauses playback and fires callback', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    var fired = false;
    controller.setSleepTimer(const Duration(milliseconds: 30),
        onFired: () => fired = true);
    expect(controller.sleepTimerRemaining, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(fired, true);
    expect(api.calls, contains('pause'));
    expect(controller.sleepTimerRemaining, isNull);
  });

  test('cancelSleepTimer clears a pending timer', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    controller.setSleepTimer(const Duration(seconds: 10));
    expect(controller.sleepTimerRemaining, isNotNull);
    controller.cancelSleepTimer();
    expect(controller.sleepTimerRemaining, isNull);
  });

  test('dispose cancels a pending sleep timer', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    controller.setSleepTimer(const Duration(milliseconds: 20));
    await controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(api.calls, isNot(contains('pause')));
  });

  test('wakelock ref-counts across controllers (last-off wins)', () async {
    final api1 = FakeHostApi(playerId: 7);
    final api2 = FakeHostApi(playerId: 8);
    final c1 = SecureVideoController(api: api1);
    final c2 = SecureVideoController(api: api2);
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
      {'event': 'isPlayingChanged', 'isPlaying': true},
    ], playerId: 7);
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
      {'event': 'isPlayingChanged', 'isPlaying': true},
    ], playerId: 8);

    await c1.initialize(source: const VideoSource.file('/a.enc'));
    await pumpEventQueue();
    expect(api1.keepAwake, [true]); // 0 -> 1 acquire flips native flag

    await c2.initialize(source: const VideoSource.file('/b.enc'));
    await pumpEventQueue();
    expect(api2.keepAwake, isEmpty); // already held — no second native flip

    await c1.dispose();
    expect(api1.keepAwake, [true]); // still held by c2 — no release

    await c2.dispose();
    expect(api2.keepAwake, [false]); // 1 -> 0 release flips native flag off
  });

  test('setKeepScreenAwake override forces on/off and back to auto', () async {
    mockEvents([
      {'event': 'initialized', 'duration': 1000, 'width': 1, 'height': 1},
    ]);
    await controller.initialize(source: const VideoSource.file('/x.enc'));
    expect(api.keepAwake, isEmpty); // not playing, auto -> off
    controller.setKeepScreenAwake(true);
    expect(api.keepAwake, [true]);
    controller.setKeepScreenAwake(false);
    expect(api.keepAwake, [true, false]);
    controller.setKeepScreenAwake(null); // auto; still not playing -> stays off
    expect(api.keepAwake, [true, false]);
  });
}

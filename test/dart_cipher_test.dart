import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_video_player/secure_video_player.dart';

/// Builds a request frame: [1B dir][8B offset BE][payload].
ByteData _frame(int direction, int offset, List<int> payload) {
  final bytes = Uint8List(9 + payload.length);
  final view = ByteData.sublistView(bytes);
  view.setUint8(0, direction);
  view.setInt64(1, offset, Endian.big);
  bytes.setAll(9, payload);
  return view;
}

/// Delegates by transforming the parsed chunk; records what it received so the
/// test can assert the frame decoded correctly.
class _RecordingDelegate extends DartCipherDelegate {
  int? decChunkLen;
  int? decOffset;
  int? encOffset;

  @override
  FutureOr<Uint8List> decrypt(Uint8List chunk, int fileOffset) {
    decChunkLen = chunk.length;
    decOffset = fileOffset;
    return Uint8List.fromList(chunk.map((b) => b ^ 0xAB).toList());
  }

  @override
  FutureOr<Uint8List> encrypt(Uint8List chunk, int fileOffset) {
    encOffset = fileOffset;
    return Uint8List.fromList(chunk.map((b) => b ^ 0xCD).toList());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<ByteData?> send(String channelId, ByteData frame) {
    final completer = Completer<ByteData?>();
    messenger.handlePlatformMessage(
      '$kDartCipherChannelPrefix$channelId',
      frame,
      completer.complete,
    );
    return completer.future;
  }

  test('decodes frame and dispatches decrypt with offset + chunk', () async {
    final delegate = _RecordingDelegate();
    final reg = DartCipher.register('t1', delegate);
    addTearDown(reg.dispose);

    final reply = await send('t1', _frame(0, 4096, [1, 2, 3, 4]));

    expect(delegate.decOffset, 4096);
    expect(delegate.decChunkLen, 4);
    final out = reply!.buffer.asUint8List(reply.offsetInBytes, reply.lengthInBytes);
    expect(out, [1 ^ 0xAB, 2 ^ 0xAB, 3 ^ 0xAB, 4 ^ 0xAB]);
  });

  test('direction byte 1 routes to encrypt', () async {
    final delegate = _RecordingDelegate();
    final reg = DartCipher.register('t2', delegate);
    addTearDown(reg.dispose);

    final reply = await send('t2', _frame(1, 8, [10, 20]));

    expect(delegate.encOffset, 8);
    final out = reply!.buffer.asUint8List(reply.offsetInBytes, reply.lengthInBytes);
    expect(out, [10 ^ 0xCD, 20 ^ 0xCD]);
  });

  test('delegate throw replies null (never throws across channel)', () async {
    final reg = DartCipher.register('t3', _ThrowingDelegate());
    addTearDown(reg.dispose);

    final reply = await send('t3', _frame(0, 0, [1, 2, 3]));
    expect(reply, isNull);
  });

  test('length mismatch replies null', () async {
    final reg = DartCipher.register('t4', _ShortDelegate());
    addTearDown(reg.dispose);

    final reply = await send('t4', _frame(0, 0, [1, 2, 3, 4]));
    expect(reply, isNull);
  });

  test('dispose unregisters the handler', () async {
    final reg = DartCipher.register('t5', _RecordingDelegate());
    reg.dispose();

    // No handler -> platform message resolves to null.
    final reply = await send('t5', _frame(0, 0, [1, 2, 3]));
    expect(reply, isNull);
  });

  test('duplicate register on a live channelId throws StateError', () {
    final reg = DartCipher.register('dup', _RecordingDelegate());
    addTearDown(reg.dispose);
    expect(
      () => DartCipher.register('dup', _RecordingDelegate()),
      throwsStateError,
    );
  });

  test('re-register is allowed after the first is disposed', () {
    DartCipher.register('reuse', _RecordingDelegate()).dispose();
    final reg = DartCipher.register('reuse', _RecordingDelegate());
    addTearDown(reg.dispose);
    // The reused channel routes to the new delegate (no exception above).
    expect(reg, isNotNull);
  });
}

class _ThrowingDelegate extends DartCipherDelegate {
  @override
  FutureOr<Uint8List> decrypt(Uint8List chunk, int fileOffset) =>
      throw StateError('boom');
}

class _ShortDelegate extends DartCipherDelegate {
  @override
  FutureOr<Uint8List> decrypt(Uint8List chunk, int fileOffset) =>
      Uint8List(chunk.length - 1);
}

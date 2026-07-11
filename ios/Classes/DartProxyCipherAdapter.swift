import Flutter
import Foundation

/// Built-in adapter that proxies each read chunk to a pure-Dart
/// `DartCipherDelegate` over a dedicated FlutterBasicMessageChannel
/// (binary codec), named `secure_video_player/dart_cipher_<channelId>`.
///
/// Request frame: [1B direction: 0=decrypt, 1=encrypt][8B file offset, big-endian][payload].
/// Reply: transformed bytes (same length). On timeout / wrong length / error
/// the buffer is left untouched so the decoder surfaces a read error (matching
/// the built-in adapters' failure convention).
///
/// Threading: transform() runs on the resource-loader queue (playback) or the
/// crypto queue (file encrypt) — never the main thread. FlutterBasicMessageChannel
/// must be used from the main thread, so we dispatch the send to the main queue
/// and block the caller on a semaphore. Main stays free to deliver Dart's reply,
/// so there is no deadlock. A main-thread call fails fast instead of deadlocking.
final class DartProxyCipherAdapter: CipherAdapter {

    private let messenger: FlutterBinaryMessenger
    private var channel: FlutterBasicMessageChannel?
    private var timeout: TimeInterval = 5.0

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
    }

    func initialize(params: [String: Any?]) throws {
        guard let channelId = params["channelId"] as? String else {
            throw CipherError.badParams("dartProxy requires a 'channelId' string")
        }
        if let ms = params["timeoutMs"] as? NSNumber { timeout = ms.doubleValue / 1000.0 }
        channel = FlutterBasicMessageChannel(
            name: "\(SvpProtocol.channelDartCipherPrefix)\(channelId)",
            binaryMessenger: messenger,
            codec: FlutterBinaryCodec.sharedInstance())
    }

    /// Playback (resource-loader) path: decrypt, non-throwing. On timeout /
    /// wrong length / error the buffer is left untouched so the decoder
    /// surfaces a read error (matching the built-in adapters' convention).
    func transform(_ buffer: inout Data, filePosition: Int64) {
        guard let reply = try? send(buffer, filePosition: filePosition, encrypt: false)
        else { return }
        buffer = reply
    }

    /// File-cryptor path: throwing so a proxy failure fails the whole job
    /// instead of writing raw (untransformed) bytes to the output.
    func transform(_ buffer: inout Data, filePosition: Int64, encrypt: Bool) throws {
        buffer = try send(buffer, filePosition: filePosition, encrypt: encrypt)
    }

    /// Sends [1B dir][8B offset BE][payload] and returns the same-length reply.
    /// Throws on main-thread misuse, missing channel, timeout, or short reply.
    private func send(_ buffer: Data, filePosition: Int64, encrypt: Bool) throws -> Data {
        let length = buffer.count
        if length == 0 { return buffer }
        guard !Thread.isMainThread else {
            assertionFailure("DartProxyCipherAdapter.transform must not run on the main thread")
            throw CipherError.transformFailed("dartProxy transform ran on the main thread")
        }
        guard let channel else {
            throw CipherError.transformFailed("dartProxy channel not initialized")
        }

        // Frame: [dir: 0=decrypt, 1=encrypt][offset 8B BE][payload].
        var request = Data(capacity: 9 + length)
        request.append(encrypt ? 1 : 0)
        var beOffset = filePosition.bigEndian
        withUnsafeBytes(of: &beOffset) { request.append(contentsOf: $0) }
        request.append(buffer)

        let semaphore = DispatchSemaphore(value: 0)
        var reply: Data?
        DispatchQueue.main.async {
            channel.sendMessage(request) { response in
                reply = response as? Data
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw CipherError.transformFailed("dartProxy transform timed out")
        }
        guard let reply, reply.count == length else {
            throw CipherError.transformFailed(
                "dartProxy returned \(reply?.count ?? 0) bytes, expected \(length)")
        }
        return reply
    }
}

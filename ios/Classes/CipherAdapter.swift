import CommonCrypto
import Flutter
import Foundation

/// Position-addressable cipher: transform must depend only on
/// (bytes, filePosition) so playback can seek anywhere in O(1).
public protocol CipherAdapter {
    func initialize(params: [String: Any?]) throws
    /// In-place transform of `buffer` read at absolute `filePosition`.
    func transform(_ buffer: inout Data, filePosition: Int64)
    func plaintextSize(cipherFileSize: Int64) -> Int64
}

public extension CipherAdapter {
    func plaintextSize(cipherFileSize: Int64) -> Int64 { cipherFileSize }

    /// Encrypt-aware, throwing variant used by the file-cryptor path so a
    /// transform failure fails the job instead of silently writing raw bytes.
    /// Default delegates to the legacy non-throwing transform (direction is
    /// irrelevant for the symmetric built-in ciphers).
    func transform(_ buffer: inout Data, filePosition: Int64, encrypt: Bool) throws {
        transform(&buffer, filePosition: filePosition)
    }
}

enum CipherError: Error, LocalizedError {
    case badParams(String)
    case notRegistered(String)
    case transformFailed(String)

    var errorDescription: String? {
        switch self {
        case .badParams(let m): return m
        case .notRegistered(let n): return "No CipherAdapter registered for '\(n)'"
        case .transformFailed(let m): return m
        }
    }
}

/// Name -> factory. Apps register custom ciphers in AppDelegate and reference
/// them from Dart with CryptoScheme.custom(adapterName:).
public final class CipherRegistry {
    public static let shared = CipherRegistry()
    private var factories: [String: () -> CipherAdapter] = [:]
    private let lock = NSLock()

    private init() {
        register(SvpProtocol.schemeNone) { NoneAdapter() }
        register(SvpProtocol.schemeXorLegacy) { XorLegacyAdapter() }
        register(SvpProtocol.schemeAesCtr) { AesCtrAdapter() }
    }

    public func register(_ name: String, factory: @escaping () -> CipherAdapter) {
        lock.lock(); defer { lock.unlock() }
        factories[name] = factory
    }

    func isRegistered(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return factories[name] != nil
    }

    func create(_ name: String, params: [String: Any?]) throws -> CipherAdapter {
        lock.lock()
        let factory = factories[name]
        lock.unlock()
        guard let factory else { throw CipherError.notRegistered(name) }
        let adapter = factory()
        try adapter.initialize(params: params)
        return adapter
    }
}

final class NoneAdapter: CipherAdapter {
    func initialize(params: [String: Any?]) throws {}
    func transform(_ buffer: inout Data, filePosition: Int64) {}
}

/// Hulkenstein-compatible: XOR bytes in [skipOffset, skipOffset+corruptionSize)
/// with `key`; pass the rest through. Involution: encrypt == decrypt.
final class XorLegacyAdapter: CipherAdapter {
    private var skipOffset: Int64 = 512
    private var corruptionSize: Int64 = 256
    private var key: UInt8 = 0xAB

    func initialize(params: [String: Any?]) throws {
        if let v = params["skipOffset"] as? NSNumber { skipOffset = v.int64Value }
        if let v = params["corruptionSize"] as? NSNumber { corruptionSize = v.int64Value }
        if let v = params["key"] as? NSNumber { key = UInt8(truncating: v) }
    }

    func transform(_ buffer: inout Data, filePosition: Int64) {
        let length = Int64(buffer.count)
        let rangeStart = skipOffset
        let rangeEnd = skipOffset + corruptionSize
        if filePosition >= rangeEnd || filePosition + length <= rangeStart { return }
        let from = Int(max(0, rangeStart - filePosition))
        let to = Int(min(length, rangeEnd - filePosition))
        let k = key
        buffer.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in from..<to { bytes[i] ^= k }
        }
    }
}

/// AES-CTR: keystream block i = AES-ECB(key, nonce(8B) || i(8B big-endian)).
/// Batch-generates the keystream with one CCCrypt call (hardware AES).
final class AesCtrAdapter: CipherAdapter {
    private var key = Data()
    private var nonce = Data()

    func initialize(params: [String: Any?]) throws {
        // Pigeon delivers Uint8List as FlutterStandardTypedData.
        guard let keyData = params["key"] as? FlutterStandardTypedData else {
            throw CipherError.badParams("aesCtr requires 'key' bytes")
        }
        key = keyData.data
        guard key.count == 16 || key.count == 32 else {
            throw CipherError.badParams("AES key must be 16 or 32 bytes")
        }
        guard let nonceData = params["nonce"] as? FlutterStandardTypedData else {
            throw CipherError.badParams("aesCtr requires 'nonce' bytes")
        }
        nonce = nonceData.data
        guard nonce.count == 8 else { throw CipherError.badParams("nonce must be 8 bytes") }
    }

    func transform(_ buffer: inout Data, filePosition: Int64) {
        let length = buffer.count
        if length == 0 { return }
        let firstBlock = filePosition / 16
        let skip = Int(filePosition % 16)
        let blockCount = (skip + length + 15) / 16

        var counters = Data(count: blockCount * 16)
        counters.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            nonce.withUnsafeBytes { nonceRaw in
                let nonceBytes = nonceRaw.bindMemory(to: UInt8.self)
                for b in 0..<blockCount {
                    let base = b * 16
                    for j in 0..<8 { bytes[base + j] = nonceBytes[j] }
                    var index = UInt64(firstBlock + Int64(b))
                    for j in stride(from: 7, through: 0, by: -1) {
                        bytes[base + 8 + j] = UInt8(index & 0xFF)
                        index >>= 8
                    }
                }
            }
        }

        var keystream = Data(count: blockCount * 16)
        var moved = 0
        let status = keystream.withUnsafeMutableBytes { ksRaw in
            counters.withUnsafeBytes { ctrRaw in
                key.withUnsafeBytes { keyRaw in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyRaw.baseAddress, key.count,
                        nil,
                        ctrRaw.baseAddress, blockCount * 16,
                        ksRaw.baseAddress, blockCount * 16,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return }

        buffer.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            keystream.withUnsafeBytes { ksRaw in
                let ks = ksRaw.bindMemory(to: UInt8.self)
                for i in 0..<length { bytes[i] ^= ks[skip + i] }
            }
        }
    }
}

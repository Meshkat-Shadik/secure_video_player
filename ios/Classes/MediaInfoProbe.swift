import AVFoundation
import CoreMedia
import Foundation

/// Probes container + per-stream metadata from a possibly encrypted file.
/// Encrypted sources load through the same CipherResourceLoaderDelegate as
/// playback, so plaintext never touches disk.
enum MediaInfoProbe {

    static func probe(
        path: String, schemeType: String, params: [String: Any?]
    ) throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: path) else {
            throw PigeonError(code: SvpProtocol.errorFileNotFound,
                              message: "File not found: \(path)", details: nil)
        }

        // dartProxy dispatches its channel send to the main thread, which the
        // semaphore below blocks — every chunk would time out and the main
        // thread would freeze. Reject up front.
        if schemeType == SvpProtocol.schemeDartProxy {
            throw PigeonError(
                code: SvpProtocol.errorPlatformNotSupported,
                message: "getMediaInfo is not supported with the dartProxy scheme; "
                    + "probe before encrypting or use a native scheme",
                details: nil)
        }

        let asset: AVURLAsset
        // Strong ref kept for the probe's lifetime — the loader is weak.
        var loader: CipherResourceLoaderDelegate?
        if schemeType == SvpProtocol.schemeNone {
            asset = AVURLAsset(url: URL(fileURLWithPath: path))
        } else {
            let adapter: CipherAdapter
            do {
                adapter = try CipherRegistry.shared.create(schemeType, params: params)
            } catch {
                throw PigeonError(code: SvpProtocol.errorAdapterNotRegistered,
                                  message: error.localizedDescription, details: nil)
            }
            let delegate = CipherResourceLoaderDelegate(filePath: path, adapter: adapter)
            asset = AVURLAsset(url: CipherResourceLoaderDelegate.makeURL(filePath: path))
            asset.resourceLoader.setDelegate(
                delegate, queue: DispatchQueue(label: "svp.probe.loader"))
            loader = delegate
        }
        defer { _ = loader } // keep alive until probing completes

        // Block until tracks/duration load (probe runs on the platform thread
        // briefly; local file IO, not network).
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
            semaphore.signal()
        }
        // TODO(review): move probe off the platform thread; the main-thread
        // semaphore also risks ANR-like stalls for native schemes
        _ = semaphore.wait(timeout: .now() + 10)

        var error: NSError?
        guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded else {
            throw PigeonError(code: SvpProtocol.errorCorruptStream,
                              message: "Cannot probe media: \(error?.localizedDescription ?? "tracks unavailable")",
                              details: nil)
        }

        let durationMs = asset.duration.isNumeric
            ? Int64(CMTimeGetSeconds(asset.duration) * 1000) : 0

        var rotation: Int64?
        var streams: [MediaStreamInfo?] = []
        for track in asset.tracks {
            let desc = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let codec = desc.map {
                fourCCString(CMFormatDescriptionGetMediaSubType($0))
            }
            switch track.mediaType {
            case .video:
                let t = track.preferredTransform
                let degrees = Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded())
                rotation = Int64(((degrees % 360) + 360) % 360)
                streams.append(MediaStreamInfo(
                    type: "video",
                    codec: codec,
                    width: Int64(track.naturalSize.width),
                    height: Int64(track.naturalSize.height),
                    frameRate: Double(track.nominalFrameRate),
                    bitrate: Int64(track.estimatedDataRate),
                    language: language(of: track)
                ))
            case .audio:
                var sampleRate: Int64?
                var channels: Int64?
                if let desc, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    sampleRate = Int64(asbd.mSampleRate)
                    channels = Int64(asbd.mChannelsPerFrame)
                }
                streams.append(MediaStreamInfo(
                    type: "audio",
                    codec: codec,
                    bitrate: Int64(track.estimatedDataRate),
                    sampleRate: sampleRate,
                    channels: channels,
                    language: language(of: track)
                ))
            case .text, .subtitle, .closedCaption:
                streams.append(MediaStreamInfo(
                    type: "subtitle", codec: codec, language: language(of: track)))
            default:
                streams.append(MediaStreamInfo(type: "unknown", codec: codec))
            }
        }

        return MediaInfo(
            durationMs: durationMs,
            container: URL(fileURLWithPath: path).pathExtension.lowercased(),
            rotation: rotation,
            bitrate: nil,
            streams: streams
        )
    }

    private static func language(of track: AVAssetTrack) -> String? {
        let code = track.languageCode
        return (code == nil || code == "und") ? nil : code
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        // FourCC bytes >= 0x80 trap when forced into CChar; build from UInt8
        // and decode with a non-trapping single-byte encoding.
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
        ]
        let string = String(bytes: bytes, encoding: .ascii)
            ?? String(bytes: bytes, encoding: .macOSRoman) ?? ""
        return string.trimmingCharacters(in: .whitespaces)
    }
}

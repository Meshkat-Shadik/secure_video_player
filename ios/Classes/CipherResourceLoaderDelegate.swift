import AVFoundation
import CoreServices
import Foundation

/// Serves decrypted byte ranges of an encrypted local file to AVPlayer.
/// The asset uses a custom URL scheme so AVFoundation routes every read
/// through this delegate; plaintext never touches disk.
final class CipherResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "svp-encrypted"

    private let filePath: String
    private let adapter: CipherAdapter
    private let queue = DispatchQueue(label: "svp.resource-loader")
    private let chunkSize = 512 * 1024

    init(filePath: String, adapter: CipherAdapter) {
        self.filePath = filePath
        self.adapter = adapter
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        queue.async { [weak self] in self?.handle(loadingRequest) }
        return true
    }

    private func handle(_ request: AVAssetResourceLoadingRequest) {
        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            request.finishLoading(with: NSError(
                domain: "svp", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "File not found: \(filePath)"]))
            return
        }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0

        if let info = request.contentInformationRequest {
            info.contentType = contentType()
            info.contentLength = adapter.plaintextSize(cipherFileSize: fileSize ?? 0)
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        var position = dataRequest.requestedOffset
        var remaining = Int64(dataRequest.requestedLength)
        if dataRequest.requestsAllDataToEndOfResource {
            remaining = (fileSize ?? 0) - position
        }

        while remaining > 0 {
            if request.isCancelled { return }
            let toRead = Int(min(Int64(chunkSize), remaining))
            handle.seek(toFileOffset: UInt64(position))
            var data = handle.readData(ofLength: toRead)
            if data.isEmpty { break }
            adapter.transform(&data, filePosition: position)
            dataRequest.respond(with: data)
            position += Int64(data.count)
            remaining -= Int64(data.count)
        }
        request.finishLoading()
    }

    private func contentType() -> String {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v", "enc", "": return AVFileType.mp4.rawValue
        case "mov": return AVFileType.mov.rawValue
        case "m4a": return AVFileType.m4a.rawValue
        default: return AVFileType.mp4.rawValue
        }
    }

    /// URL AVPlayer opens; the bogus scheme forces delegate routing.
    static func makeURL(filePath: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        components.path = filePath.hasPrefix("/") ? filePath : "/\(filePath)"
        return components.url!
    }
}

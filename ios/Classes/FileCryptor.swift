import Foundation

/// Streams a file through a CipherAdapter off the main thread in 1 MB chunks.
/// Encrypt == decrypt for all built-in schemes (XOR keystreams).
final class FileCryptor {

    struct Progress {
        let operationId: String
        let bytesProcessed: Int64
        let totalBytes: Int64
        let done: Bool
        var error: String?
        var errorCode: String?

        var asMap: [String: Any] {
            var m: [String: Any] = [
                "operationId": operationId,
                "bytesProcessed": bytesProcessed,
                "totalBytes": totalBytes,
                "done": done,
            ]
            if let error { m["error"] = error }
            if let errorCode { m["errorCode"] = errorCode }
            return m
        }
    }

    static let shared = FileCryptor()
    private let queue = DispatchQueue(label: "svp.file-cryptor", qos: .utility)
    private var cancelled = Set<String>()
    private let lock = NSLock()

    private let chunk = 1024 * 1024

    func start(
        inputPath: String,
        outputPath: String,
        adapter: CipherAdapter,
        onProgress: @escaping (Progress) -> Void
    ) -> String {
        let id = UUID().uuidString
        queue.async { [self] in
            guard let input = FileHandle(forReadingAtPath: inputPath) else {
                onProgress(Progress(operationId: id, bytesProcessed: 0, totalBytes: 0,
                                    done: true, error: "Input not found: \(inputPath)",
                                    errorCode: "fileNotFound"))
                return
            }
            defer { try? input.close() }

            FileManager.default.createFile(atPath: outputPath, contents: nil)
            guard let output = FileHandle(forWritingAtPath: outputPath) else {
                onProgress(Progress(operationId: id, bytesProcessed: 0, totalBytes: 0,
                                    done: true, error: "Cannot write: \(outputPath)",
                                    errorCode: "corruptStream"))
                return
            }
            defer { try? output.close() }

            let total = (try? FileManager.default
                .attributesOfItem(atPath: inputPath)[.size] as? Int64) ?? 0
            var position: Int64 = 0

            while true {
                if isCancelled(id) {
                    try? output.close()
                    try? FileManager.default.removeItem(atPath: outputPath)
                    onProgress(Progress(operationId: id, bytesProcessed: position,
                                        totalBytes: total ?? 0, done: true,
                                        error: "Cancelled", errorCode: "unknown"))
                    return
                }
                var data = input.readData(ofLength: chunk)
                if data.isEmpty { break }
                adapter.transform(&data, filePosition: position)
                output.write(data)
                position += Int64(data.count)
                onProgress(Progress(operationId: id, bytesProcessed: position,
                                    totalBytes: total ?? 0, done: false))
            }
            onProgress(Progress(operationId: id, bytesProcessed: position,
                                totalBytes: total ?? 0, done: true))
            clear(id)
        }
        return id
    }

    func cancel(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        cancelled.insert(id)
    }

    private func isCancelled(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    private func clear(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        cancelled.remove(id)
    }
}

import AVFoundation
import AVKit
import Flutter
import Foundation

/// Event sink that buffers events until the Dart listener attaches.
final class QueuingEventSink: NSObject {
    private var sink: FlutterEventSink?
    private var queue: [Any] = []

    func setDelegate(_ newSink: FlutterEventSink?) {
        sink = newSink
        if let s = newSink {
            queue.forEach { s($0) }
            queue.removeAll()
        }
    }

    func success(_ event: Any) {
        DispatchQueue.main.async { [self] in
            if let s = sink { s(event) } else { queue.append(event) }
        }
    }

    func endOfStream() {
        DispatchQueue.main.async { [self] in sink?(FlutterEndOfEventStream) }
    }
}

/// One native player: AVPlayer + optional Flutter texture output, event sink,
/// resource-loader decryption for encrypted sources.
final class PlayerInstance: NSObject, FlutterTexture {

    let playerId: Int64
    let player: AVPlayer
    let events = QueuingEventSink()
    var backgroundPlayback = false
    var wasPlayingBeforeBackground = false

    private let item: AVPlayerItem
    // Strong ref: AVAssetResourceLoader only holds its delegate weakly.
    private let loaderDelegate: CipherResourceLoaderDelegate?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private weak var textureRegistry: FlutterTextureRegistry?
    var textureId: Int64 = -1

    private var desiredRate: Float = 1.0
    private var looping: Bool
    private var initializedSent = false
    private var positionTimer: Timer?
    private var latestPixelBuffer: CVPixelBuffer?

    /// Set by the platform view when it hosts this player's AVPlayerLayer.
    var pipController: AVPictureInPictureController?

    init(
        playerId: Int64,
        request: CreateRequest,
        resolvedPath: String,
        textureRegistry: FlutterTextureRegistry?
    ) throws {
        self.playerId = playerId
        self.looping = request.looping
        self.textureRegistry = textureRegistry

        let params = request.schemeParams.reduce(into: [String: Any?]()) {
            if let k = $1.key { $0[k] = $1.value }
        }

        let asset: AVURLAsset
        if request.schemeType == "none" {
            let url = request.sourceType == "url"
                ? URL(string: resolvedPath)!
                : URL(fileURLWithPath: resolvedPath)
            asset = AVURLAsset(url: url)
            loaderDelegate = nil
        } else {
            let adapter = try CipherRegistry.shared.create(request.schemeType, params: params)
            let delegate = CipherResourceLoaderDelegate(
                filePath: resolvedPath, adapter: adapter)
            asset = AVURLAsset(url: CipherResourceLoaderDelegate.makeURL(filePath: resolvedPath))
            asset.resourceLoader.setDelegate(
                delegate, queue: DispatchQueue(label: "svp.loader.\(playerId)"))
            loaderDelegate = delegate
        }

        item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none

        super.init()

        if request.renderMode == "texture" {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            item.add(output)
            videoOutput = output
            if let registry = textureRegistry {
                textureId = registry.register(self)
            }
        }

        observe()

        player.volume = Float(request.volume)
        desiredRate = 1.0
        if request.startPositionMs > 0 {
            player.seek(to: CMTime(value: request.startPositionMs, timescale: 1000))
        }
        if request.autoPlay { player.play() }
    }

    // ---- FlutterTexture ----

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let output = videoOutput else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            latestPixelBuffer = buffer
        }
        guard let buffer = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        guard let output = videoOutput, textureId >= 0 else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time) {
            textureRegistry?.textureFrameAvailable(textureId)
        }
    }

    // ---- observation ----

    private func observe() {
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "presentationSize", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [.new], context: nil)
        player.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onPlayedToEnd),
            name: .AVPlayerItemDidPlayToEndTime, object: item)
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        switch keyPath {
        case "status":
            if item.status == .readyToPlay {
                sendInitializedIfNeeded()
            } else if item.status == .failed {
                let message = item.error?.localizedDescription ?? "Playback failed"
                // Decryption failures surface as unparseable media.
                let code = (item.error as NSError?)?.domain == "svp"
                    ? "fileNotFound" : "corruptStream"
                events.success([
                    "event": "error", "code": code, "message": message,
                ])
            }
        case "presentationSize":
            let size = item.presentationSize
            if size.width > 0, size.height > 0 {
                events.success([
                    "event": "videoSize",
                    "width": Int(size.width), "height": Int(size.height),
                ])
            }
        case "playbackBufferEmpty":
            if item.isPlaybackBufferEmpty { events.success(["event": "buffering"]) }
        case "playbackLikelyToKeepUp":
            if item.isPlaybackLikelyToKeepUp, initializedSent {
                events.success(["event": "ready"])
            }
        case "timeControlStatus":
            let playing = player.timeControlStatus == .playing
            events.success(["event": "isPlayingChanged", "isPlaying": playing])
            if playing {
                startTicker()
                displayLink?.isPaused = false
            }
        default:
            break
        }
    }

    private func sendInitializedIfNeeded() {
        guard !initializedSent else { return }
        initializedSent = true
        let duration = item.duration
        let ms = duration.isNumeric ? Int64(CMTimeGetSeconds(duration) * 1000) : 0
        let size = item.presentationSize
        events.success([
            "event": "initialized",
            "duration": max(0, ms),
            "width": Int(size.width),
            "height": Int(size.height),
        ])
        if videoOutput != nil {
            let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        startTicker()
    }

    @objc private func onPlayedToEnd() {
        if looping {
            player.seek(to: .zero)
            player.rate = desiredRate
        } else {
            player.pause()
            events.success(["event": "completed"])
        }
    }

    private func startTicker() {
        guard positionTimer == nil else { return }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in self?.sendPosition()
        }
    }

    private func sendPosition() {
        let pos = Int64(CMTimeGetSeconds(player.currentTime()) * 1000)
        var buffered: Int64 = 0
        if let range = item.loadedTimeRanges.first?.timeRangeValue {
            buffered = Int64(CMTimeGetSeconds(CMTimeAdd(range.start, range.duration)) * 1000)
        }
        events.success([
            "event": "position",
            "position": max(0, pos),
            "buffered": max(0, buffered),
        ])
    }

    // ---- controls ----

    func play() {
        if item.status == .readyToPlay,
           CMTimeCompare(player.currentTime(), item.duration) >= 0 {
            player.seek(to: .zero)
        }
        player.rate = desiredRate
    }

    func pause() { player.pause() }

    func seekTo(ms: Int64) {
        let time = CMTime(value: ms, timescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setSpeed(_ speed: Double) {
        desiredRate = Float(speed)
        if player.timeControlStatus == .playing { player.rate = desiredRate }
    }

    func setVolume(_ volume: Double) { player.volume = Float(volume) }
    func setLooping(_ value: Bool) { looping = value }

    var positionMs: Int64 {
        max(0, Int64(CMTimeGetSeconds(player.currentTime()) * 1000))
    }

    // ---- tracks ----

    private func selectionGroup(for type: String) -> AVMediaSelectionGroup? {
        let characteristic: AVMediaCharacteristic
        switch type {
        case "audio": characteristic = .audible
        case "subtitle": characteristic = .legible
        default: return nil
        }
        return item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
    }

    func getTracks(type: String) -> [TrackInfo] {
        // Local files expose one video track; quality ladders are an
        // HLS/DASH concept, so 'video' returns empty here.
        guard let group = selectionGroup(for: type) else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            TrackInfo(
                id: "\(index)",
                type: type,
                selected: option == selected,
                label: option.displayName,
                language: option.locale?.identifier,
                width: nil, height: nil, bitrate: nil
            )
        }
    }

    func selectTrack(type: String, trackId: String?) {
        guard let group = selectionGroup(for: type) else { return }
        if let trackId, let index = Int(trackId), index < group.options.count {
            item.select(group.options[index], in: group)
        } else {
            item.select(nil, in: group)
        }
    }

    // ---- pip ----

    func enterPictureInPicture() -> Bool {
        guard let pip = pipController, pip.isPictureInPicturePossible else { return false }
        pip.startPictureInPicture()
        events.success(["event": "pipChanged", "active": true])
        return true
    }

    // ---- teardown ----

    func dispose() {
        positionTimer?.invalidate()
        positionTimer = nil
        displayLink?.invalidate()
        displayLink = nil
        player.pause()
        item.removeObserver(self, forKeyPath: "status")
        item.removeObserver(self, forKeyPath: "presentationSize")
        item.removeObserver(self, forKeyPath: "playbackBufferEmpty")
        item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        player.removeObserver(self, forKeyPath: "timeControlStatus")
        NotificationCenter.default.removeObserver(self)
        if textureId >= 0 {
            textureRegistry?.unregisterTexture(textureId)
            textureId = -1
        }
        player.replaceCurrentItem(with: nil)
        events.endOfStream()
    }
}

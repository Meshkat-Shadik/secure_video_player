import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit

public class SecureVideoPlayerPlugin: NSObject, FlutterPlugin, SecureVideoHostApi {

    private var players: [Int64: PlayerInstance] = [:]
    private var eventChannels: [Int64: FlutterEventChannel] = [:]
    private var nextPlayerId: Int64 = 1
    private let cryptoEvents = QueuingEventSink()
    private weak var registrar: FlutterPluginRegistrar?
    private var secureField: UITextField?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SecureVideoPlayerPlugin()
        instance.registrar = registrar
        SecureVideoHostApiSetup.setUp(
            binaryMessenger: registrar.messenger(), api: instance)

        // Built-in adapter that proxies chunks to a pure-Dart DartCipherDelegate.
        // Registered here because it needs the engine's BinaryMessenger.
        let messenger = registrar.messenger()
        CipherRegistry.shared.register(SvpProtocol.schemeDartProxy) {
            DartProxyCipherAdapter(messenger: messenger)
        }

        let cryptoChannel = FlutterEventChannel(
            name: SvpProtocol.channelCryptoEvents,
            binaryMessenger: registrar.messenger())
        cryptoChannel.setStreamHandler(SinkStreamHandler(sink: instance.cryptoEvents))

        registrar.register(
            PlayerPlatformViewFactory(plugin: instance),
            withId: SvpProtocol.platformViewType)

        instance.observeAppLifecycle()

        // isIdleTimerDisabled survives a Dart hot restart; reset it so a stale
        // wakelock from a previous run doesn't linger.
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func playerInstance(_ id: Int64) -> PlayerInstance? { players[id] }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.players.values.forEach { p in
                if !p.backgroundPlayback, p.player.timeControlStatus == .playing {
                    p.wasPlayingBeforeBackground = true
                    p.pause()
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.players.values.forEach { p in
                if p.wasPlayingBeforeBackground {
                    p.wasPlayingBeforeBackground = false
                    p.play()
                }
            }
        }
    }

    // ---- SecureVideoHostApi ----

    func create(request: CreateRequest) throws -> CreateResponse {
        if request.schemeType == SvpProtocol.schemeClearKey {
            throw PigeonError(
                code: SvpProtocol.errorPlatformNotSupported,
                message: "ClearKey DRM is Android-only. Use aesCtr on iOS.",
                details: nil)
        }
        if !CipherRegistry.shared.isRegistered(request.schemeType) {
            throw PigeonError(
                code: SvpProtocol.errorAdapterNotRegistered,
                message: "No CipherAdapter registered for '\(request.schemeType)'. "
                    + "Call CipherRegistry.shared.register(\"\(request.schemeType)\") in AppDelegate.",
                details: nil)
        }

        var resolved = request.source
        if request.sourceType == SvpProtocol.sourceAsset {
            guard let registrar,
                  let path = Bundle.main.path(
                      forResource: registrar.lookupKey(forAsset: request.source),
                      ofType: nil)
            else {
                throw PigeonError(code: SvpProtocol.errorFileNotFound,
                                  message: "Asset not found: \(request.source)",
                                  details: nil)
            }
            resolved = path
        }
        if request.sourceType != SvpProtocol.sourceUrl, !FileManager.default.fileExists(atPath: resolved) {
            throw PigeonError(code: SvpProtocol.errorFileNotFound,
                              message: "File not found: \(resolved)", details: nil)
        }

        let playerId = nextPlayerId
        nextPlayerId += 1

        let instance: PlayerInstance
        do {
            instance = try PlayerInstance(
                playerId: playerId,
                request: request,
                resolvedPath: resolved,
                textureRegistry: registrar?.textures())
        } catch let error as CipherError {
            throw PigeonError(code: SvpProtocol.errorInvalidKey,
                              message: error.localizedDescription, details: nil)
        }

        players[playerId] = instance
        let channel = FlutterEventChannel(
            name: SvpProtocol.playerEventsChannel(playerId),
            binaryMessenger: registrar!.messenger())
        channel.setStreamHandler(SinkStreamHandler(sink: instance.events))
        eventChannels[playerId] = channel

        return CreateResponse(
            playerId: playerId,
            textureId: instance.textureId >= 0 ? instance.textureId : nil)
    }

    private func instance(_ playerId: Int64) throws -> PlayerInstance {
        guard let p = players[playerId] else {
            throw PigeonError(code: SvpProtocol.errorDisposed,
                              message: "No player \(playerId)", details: nil)
        }
        return p
    }

    func dispose(playerId: Int64) throws {
        // configureMediaControls enables on the main queue; route the disable
        // through the same queue so a configure-then-dispose runs in call order
        // and never disables before the enable lands. The owner-guard in
        // disable() prevents a stale disable from clobbering a newer owner.
        DispatchQueue.main.async {
            NowPlayingCenter.shared.disable(playerId: playerId)
        }
        players.removeValue(forKey: playerId)?.dispose()
        eventChannels.removeValue(forKey: playerId)?.setStreamHandler(nil)
    }

    func play(playerId: Int64) throws { try instance(playerId).play() }
    func pause(playerId: Int64) throws { try instance(playerId).pause() }

    func seekTo(playerId: Int64, positionMs: Int64) throws {
        try instance(playerId).seekTo(ms: positionMs)
    }

    func setSpeed(playerId: Int64, speed: Double) throws {
        try instance(playerId).setSpeed(speed)
    }

    func setLooping(playerId: Int64, looping: Bool) throws {
        try instance(playerId).setLooping(looping)
    }

    func setVolume(playerId: Int64, volume: Double) throws {
        try instance(playerId).setVolume(volume)
    }

    func getPosition(playerId: Int64) throws -> Int64 {
        try instance(playerId).positionMs
    }

    func getTracks(playerId: Int64, type: String) throws -> [TrackInfo] {
        try instance(playerId).getTracks(type: type)
    }

    func selectTrack(playerId: Int64, type: String, trackId: String?) throws {
        try instance(playerId).selectTrack(type: type, trackId: trackId)
    }

    func addExternalSubtitle(
        playerId: Int64, path: String, mimeType: String, language: String?
    ) throws {
        // AVPlayer cannot sideload SRT/VTT without re-muxing. Embed subtitle
        // tracks in the MP4, or render them Flutter-side.
        throw PigeonError(
            code: SvpProtocol.errorPlatformNotSupported,
            message: "External subtitles are not supported on iOS; "
                + "embed the track in the container instead.",
            details: nil)
    }

    func enterPictureInPicture(playerId: Int64) throws -> Bool {
        try instance(playerId).enterPictureInPicture()
    }

    func setBackgroundPlayback(playerId: Int64, enabled: Bool) throws {
        let p = try instance(playerId)
        p.backgroundPlayback = enabled
        if enabled {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    func setKeepScreenAwake(enabled: Bool) throws {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = enabled
        }
    }

    func configureMediaControls(playerId: Int64, config: MediaControlsConfig) throws {
        let p = try instance(playerId)
        DispatchQueue.main.async {
            if config.enabled {
                NowPlayingCenter.shared.enable(player: p, playerId: playerId, config: config)
            } else {
                NowPlayingCenter.shared.disable(playerId: playerId)
            }
        }
    }

    func setSecureFlag(enabled: Bool) throws {
        // iOS has no FLAG_SECURE. Best effort: a secure UITextField layer
        // blanks the window in screenshots/recordings (well-known technique).
        DispatchQueue.main.async { [self] in
            guard let window = UIApplication.shared.windows.first else { return }
            if enabled {
                if secureField == nil {
                    let field = UITextField()
                    field.isSecureTextEntry = true
                    window.addSubview(field)
                    field.centerYAnchor.constraint(
                        equalTo: window.centerYAnchor).isActive = true
                    field.centerXAnchor.constraint(
                        equalTo: window.centerXAnchor).isActive = true
                    window.layer.superlayer?.addSublayer(field.layer)
                    field.layer.sublayers?.first?.addSublayer(window.layer)
                    secureField = field
                }
            } else {
                secureField?.isSecureTextEntry = false
                secureField = nil
            }
        }
    }

    func getMediaInfo(
        path: String, schemeType: String, schemeParams: [String?: Any?]
    ) throws -> MediaInfo {
        let params = schemeParams.reduce(into: [String: Any?]()) {
            if let k = $1.key { $0[k] = $1.value }
        }
        return try MediaInfoProbe.probe(path: path, schemeType: schemeType, params: params)
    }

    func setScreenBrightness(brightness: Double) throws {
        DispatchQueue.main.async {
            // -1 = "system default"; iOS has no override concept, so callers
            // should capture getScreenBrightness() first and restore it.
            if brightness >= 0 {
                UIScreen.main.brightness = CGFloat(min(max(brightness, 0), 1))
            }
        }
    }

    func getScreenBrightness() throws -> Double {
        Double(UIScreen.main.brightness)
    }

    func startCrypto(
        inputPath: String, outputPath: String, schemeType: String,
        schemeParams: [String?: Any?], encrypt: Bool
    ) throws -> String {
        let params = schemeParams.reduce(into: [String: Any?]()) {
            if let k = $1.key { $0[k] = $1.value }
        }
        let adapter: CipherAdapter
        do {
            adapter = try CipherRegistry.shared.create(schemeType, params: params)
        } catch {
            throw PigeonError(code: SvpProtocol.errorAdapterNotRegistered,
                              message: error.localizedDescription, details: nil)
        }
        return FileCryptor.shared.start(
            inputPath: inputPath, outputPath: outputPath, adapter: adapter, encrypt: encrypt
        ) { [cryptoEvents] progress in
            cryptoEvents.success(progress.asMap)
        }
    }

    func cancelCrypto(operationId: String) throws {
        FileCryptor.shared.cancel(operationId)
    }
}

/// Bridges a FlutterEventChannel to a QueuingEventSink.
final class SinkStreamHandler: NSObject, FlutterStreamHandler {
    private let sink: QueuingEventSink

    init(sink: QueuingEventSink) { self.sink = sink }

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink.setDelegate(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink.setDelegate(nil)
        return nil
    }
}

/// Platform view hosting an AVPlayerLayer (native rendering + PiP support).
final class PlayerPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    private weak var plugin: SecureVideoPlayerPlugin?

    init(plugin: SecureVideoPlayerPlugin) { self.plugin = plugin }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        let playerId = ((args as? [String: Any])?[SvpProtocol.keyPlayerId] as? NSNumber)?.int64Value
        let instance = playerId.flatMap { plugin?.playerInstance($0) }
        return PlayerPlatformView(frame: frame, instance: instance)
    }
}

final class PlayerPlatformView: NSObject, FlutterPlatformView {
    private let containerView: PlayerContainerView

    init(frame: CGRect, instance: PlayerInstance?) {
        containerView = PlayerContainerView(frame: frame)
        containerView.backgroundColor = .black
        super.init()
        if let instance {
            containerView.playerLayer.player = instance.player
            if AVPictureInPictureController.isPictureInPictureSupported() {
                instance.pipController =
                    AVPictureInPictureController(playerLayer: containerView.playerLayer)
            }
        }
    }

    func view() -> UIView { containerView }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Owns the single system Now Playing surface (MPNowPlayingInfoCenter) and the
/// remote command targets (MPRemoteCommandCenter). Only one player can own it
/// at a time — the last player to enable wins. Main-thread only.
///
/// Background audio + lock-screen controls also need the host app to declare
/// `UIBackgroundModes: [audio]` in Info.plist and an active `.playback` audio
/// session (see `setBackgroundPlayback`); this class does not fake that.
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private weak var owner: PlayerInstance?
    private var ownerId: Int64 = -1
    private var config: MediaControlsConfig?
    private var artwork: MPMediaItemArtwork?
    private var commandsRegistered = false
    // Exact targets we added, so removeCommands() doesn't wipe host-app targets.
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    func enable(player: PlayerInstance, playerId: Int64, config: MediaControlsConfig) {
        // Hand ownership over from any previous owner.
        if let previous = owner, previous !== player {
            previous.onPlaybackStateChanged = nil
        }
        owner = player
        ownerId = playerId
        self.config = config
        loadArtwork(config.artworkPath)
        registerCommands()
        player.onPlaybackStateChanged = { [weak self, weak player] in
            guard let self, let player, player === self.owner else { return }
            self.refresh()
        }
        refresh()
    }

    func disable(playerId: Int64) {
        guard ownerId == playerId else { return }  // not the current owner
        owner?.onPlaybackStateChanged = nil
        owner = nil
        ownerId = -1
        config = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        removeCommands()
    }

    private func refresh() {
        guard let owner, let config else { return }
        var info: [String: Any] = [:]
        if let title = config.title { info[MPMediaItemPropertyTitle] = title }
        if let artist = config.artist { info[MPMediaItemPropertyArtist] = artist }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let duration = owner.player.currentItem?.duration ?? .zero
        if duration.isNumeric {
            info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            max(0, CMTimeGetSeconds(owner.player.currentTime()))
        info[MPNowPlayingInfoPropertyPlaybackRate] = owner.player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ path: String?) {
        artwork = nil
        guard let path, let image = UIImage(contentsOfFile: path) else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        // Targets route to whoever currently owns Now Playing.
        let play = center.playCommand.addTarget { [weak self] _ in
            guard let owner = self?.owner else { return .noSuchContent }
            owner.play(); self?.refresh(); return .success
        }
        let pause = center.pauseCommand.addTarget { [weak self] _ in
            guard let owner = self?.owner else { return .noSuchContent }
            owner.pause(); self?.refresh(); return .success
        }
        let seek = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let owner = self?.owner,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .noSuchContent }
            owner.seekTo(ms: Int64(event.positionTime * 1000))
            self?.refresh()
            return .success
        }
        commandTargets = [
            (center.playCommand, play),
            (center.pauseCommand, pause),
            (center.changePlaybackPositionCommand, seek),
        ]
    }

    private func removeCommands() {
        guard commandsRegistered else { return }
        commandsRegistered = false
        // Remove exactly our targets so host-app targets on these commands survive.
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
    }
}

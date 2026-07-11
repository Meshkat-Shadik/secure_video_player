import Foundation

/// Wire protocol shared with Dart. Must stay in sync with
/// `lib/src/protocol.dart` and Android `SvpProtocol.kt`.
enum SvpProtocol {
    // Channels
    static let channelCryptoEvents = "secure_video_player/crypto_events"
    static let platformViewType = "secure_video_player/platform_view"
    static let channelDartCipherPrefix = "secure_video_player/dart_cipher_"
    static func playerEventsChannel(_ playerId: Int64) -> String {
        "secure_video_player/events_\(playerId)"
    }

    // Player event names + payload keys
    static let eventKey = "event"
    static let eventInitialized = "initialized"
    static let eventBuffering = "buffering"
    static let eventReady = "ready"
    static let eventPosition = "position"
    static let eventIsPlayingChanged = "isPlayingChanged"
    static let eventVideoSize = "videoSize"
    static let eventCompleted = "completed"
    static let eventPipChanged = "pipChanged"
    static let eventError = "error"

    static let keyDuration = "duration"
    static let keyWidth = "width"
    static let keyHeight = "height"
    static let keyRotationCorrection = "rotationCorrection"
    static let keyPosition = "position"
    static let keyBuffered = "buffered"
    static let keyIsPlaying = "isPlaying"
    static let keyActive = "active"
    static let keyCode = "code"
    static let keyMessage = "message"
    static let keyPlayerId = "playerId"

    // Crypto progress payload keys (channelCryptoEvents)
    static let keyOperationId = "operationId"
    static let keyBytesProcessed = "bytesProcessed"
    static let keyTotalBytes = "totalBytes"
    static let keyDone = "done"
    static let keyError = "error"
    static let keyErrorCode = "errorCode"

    // Scheme types
    static let schemeNone = "none"
    static let schemeXorLegacy = "xorLegacy"
    static let schemeAesCtr = "aesCtr"
    static let schemeClearKey = "clearKey"
    static let schemeDartProxy = "dartProxy"

    // Source types
    static let sourceFile = "file"
    static let sourceAsset = "asset"
    static let sourceUrl = "url"

    // Render modes
    static let renderTexture = "texture"
    static let renderPlatformView = "platformView"

    // Track types
    static let trackAudio = "audio"
    static let trackSubtitle = "subtitle"
    static let trackVideo = "video"

    // Error codes (SecureVideoErrorCode on the Dart side)
    static let errorInvalidKey = "invalidKey"
    static let errorFileNotFound = "fileNotFound"
    static let errorCorruptStream = "corruptStream"
    static let errorAdapterNotRegistered = "adapterNotRegistered"
    static let errorDrm = "drmError"
    static let errorPlatformNotSupported = "platformNotSupported"
    static let errorDisposed = "disposed"
    static let errorUnknown = "unknown"
}

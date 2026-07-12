package com.hulkenstein.secure_video_player

/**
 * Wire protocol shared with Dart. Must stay in sync with
 * `lib/src/protocol.dart` and iOS `SvpProtocol.swift`.
 */
object SvpProtocol {
    // Channels
    const val CHANNEL_CRYPTO_EVENTS = "secure_video_player/crypto_events"
    const val PLATFORM_VIEW_TYPE = "secure_video_player/platform_view"
    fun playerEventsChannel(playerId: Long) = "secure_video_player/events_$playerId"

    // Player event names + payload keys
    const val EVENT_KEY = "event"
    const val EVENT_INITIALIZED = "initialized"
    const val EVENT_BUFFERING = "buffering"
    const val EVENT_READY = "ready"
    const val EVENT_POSITION = "position"
    const val EVENT_IS_PLAYING_CHANGED = "isPlayingChanged"
    const val EVENT_VIDEO_SIZE = "videoSize"
    const val EVENT_COMPLETED = "completed"
    const val EVENT_PIP_CHANGED = "pipChanged"
    const val EVENT_ERROR = "error"

    const val KEY_DURATION = "duration"
    const val KEY_WIDTH = "width"
    const val KEY_HEIGHT = "height"
    const val KEY_ROTATION_CORRECTION = "rotationCorrection"
    const val KEY_POSITION = "position"
    const val KEY_BUFFERED = "buffered"
    const val KEY_IS_PLAYING = "isPlaying"
    const val KEY_ACTIVE = "active"
    const val KEY_CODE = "code"
    const val KEY_MESSAGE = "message"
    const val KEY_PLAYER_ID = "playerId"

    // Crypto progress payload keys
    const val KEY_OPERATION_ID = "operationId"
    const val KEY_BYTES_PROCESSED = "bytesProcessed"
    const val KEY_TOTAL_BYTES = "totalBytes"
    const val KEY_DONE = "done"
    const val KEY_ERROR = "error"
    const val KEY_ERROR_CODE = "errorCode"

    // Scheme types
    const val SCHEME_NONE = "none"
    const val SCHEME_XOR_LEGACY = "xorLegacy"
    const val SCHEME_AES_CTR = "aesCtr"
    const val SCHEME_CLEAR_KEY = "clearKey"

    // Source types
    const val SOURCE_FILE = "file"
    const val SOURCE_ASSET = "asset"
    const val SOURCE_URL = "url"
    const val SOURCE_CONTENT_URI = "contentUri"

    // Render modes
    const val RENDER_TEXTURE = "texture"
    const val RENDER_PLATFORM_VIEW = "platformView"

    // Track types
    const val TRACK_AUDIO = "audio"
    const val TRACK_SUBTITLE = "subtitle"
    const val TRACK_VIDEO = "video"

    // Error codes (SecureVideoErrorCode on the Dart side)
    const val ERROR_INVALID_KEY = "invalidKey"
    const val ERROR_FILE_NOT_FOUND = "fileNotFound"
    const val ERROR_CORRUPT_STREAM = "corruptStream"
    const val ERROR_ADAPTER_NOT_REGISTERED = "adapterNotRegistered"
    const val ERROR_DRM = "drmError"
    const val ERROR_PLATFORM_NOT_SUPPORTED = "platformNotSupported"
    const val ERROR_DISPOSED = "disposed"
    const val ERROR_UNKNOWN = "unknown"
}

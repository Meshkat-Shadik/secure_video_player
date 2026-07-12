package com.hulkenstein.secure_video_player

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowManager
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.PlayerView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

/** Flutter plugin entry point: implements the Pigeon host API. */
@UnstableApi
class SecureVideoPlayerPlugin : FlutterPlugin, ActivityAware, SecureVideoHostApi {

    private lateinit var context: Context
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private var activity: Activity? = null

    private val players = mutableMapOf<Long, PlayerInstance>()
    private val eventChannels = mutableMapOf<Long, EventChannel>()
    private var nextPlayerId = 1L
    private val cryptoEvents = QueuingEventSink()

    private companion object {
        const val TAG = "SecureVideoPlayer"
    }

    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStopped(a: Activity) {
            if (a != activity) return
            players.values.forEach { p ->
                if (!p.backgroundPlayback && p.player.isPlaying) {
                    p.wasPlayingBeforeBackground = true
                    p.pause()
                }
            }
        }

        override fun onActivityStarted(a: Activity) {
            if (a != activity) return
            players.values.forEach { p ->
                if (p.wasPlayingBeforeBackground) {
                    p.wasPlayingBeforeBackground = false
                    p.play()
                }
            }
        }

        override fun onActivityCreated(a: Activity, b: Bundle?) {}
        override fun onActivityResumed(a: Activity) {}
        override fun onActivityPaused(a: Activity) {}
        override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
        override fun onActivityDestroyed(a: Activity) {}
    }

    // ---- FlutterPlugin ----

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binding = flutterPluginBinding
        context = flutterPluginBinding.applicationContext
        SecureVideoHostApi.setUp(flutterPluginBinding.binaryMessenger, this)

        EventChannel(flutterPluginBinding.binaryMessenger, SvpProtocol.CHANNEL_CRYPTO_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    cryptoEvents.setDelegate(sink)
                }

                override fun onCancel(args: Any?) = cryptoEvents.setDelegate(null)
            })

        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            SvpProtocol.PLATFORM_VIEW_TYPE,
            PlayerPlatformViewFactory(players),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        SecureVideoHostApi.setUp(binding.binaryMessenger, null)
        players.values.toList().forEach { it.dispose() }
        players.clear()
        eventChannels.values.forEach { it.setStreamHandler(null) }
        eventChannels.clear()
    }

    // ---- ActivityAware ----

    override fun onAttachedToActivity(activityBinding: ActivityPluginBinding) {
        activity = activityBinding.activity
        // Clear a stale FLAG_KEEP_SCREEN_ON: a Dart hot restart resets the
        // wakelock refcount but the native window flag survives. Done here
        // (not onAttachedToEngine) because that seam has no activity/window.
        activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        activity?.application?.registerActivityLifecycleCallbacks(lifecycleCallbacks)
    }

    override fun onDetachedFromActivity() {
        activity?.application?.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    // ---- SecureVideoHostApi ----

    override fun create(request: CreateRequest): CreateResponse {
        val schemeType = request.schemeType
        if (schemeType != SvpProtocol.SCHEME_CLEAR_KEY && !CipherRegistry.isRegistered(schemeType)) {
            throw FlutterError(SvpProtocol.ERROR_ADAPTER_NOT_REGISTERED,
                "No CipherAdapter registered for '$schemeType'. " +
                    "Call CipherRegistry.register(\"$schemeType\") { ... } at app startup.")
        }

        val resolved = when (request.sourceType) {
            SvpProtocol.SOURCE_ASSET -> copyAssetToCache(request.source)
            else -> request.source
        }
        // URL and content:// sources aren't filesystem paths.
        val isPath = request.sourceType != SvpProtocol.SOURCE_URL &&
            request.sourceType != SvpProtocol.SOURCE_CONTENT_URI
        if (isPath && !File(resolved).exists()) {
            throw FlutterError(SvpProtocol.ERROR_FILE_NOT_FOUND, "File not found: $resolved")
        }

        val playerId = nextPlayerId++
        val useTexture = request.renderMode == SvpProtocol.RENDER_TEXTURE
        val surfaceProducer =
            if (useTexture) binding.textureRegistry.createSurfaceProducer() else null

        val instance = try {
            PlayerInstance(
                context,
                playerId,
                CreateRequest(
                    sourceType = request.sourceType,
                    source = resolved,
                    schemeType = request.schemeType,
                    schemeParams = request.schemeParams,
                    renderMode = request.renderMode,
                    autoPlay = request.autoPlay,
                    looping = request.looping,
                    volume = request.volume,
                    startPositionMs = request.startPositionMs,
                    minBufferMs = request.minBufferMs,
                    maxBufferMs = request.maxBufferMs,
                    bufferForPlaybackMs = request.bufferForPlaybackMs,
                ),
                surfaceProducer,
            ) { activity }
        } catch (e: IllegalArgumentException) {
            surfaceProducer?.release()
            throw FlutterError(SvpProtocol.ERROR_INVALID_KEY, e.message ?: "Invalid scheme parameters")
        }

        players[playerId] = instance
        val channel =
            EventChannel(binding.binaryMessenger, SvpProtocol.playerEventsChannel(playerId))
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                instance.events.setDelegate(sink)
            }

            override fun onCancel(args: Any?) = instance.events.setDelegate(null)
        })
        eventChannels[playerId] = channel

        return CreateResponse(playerId = playerId, textureId = surfaceProducer?.id())
    }

    private fun copyAssetToCache(assetKey: String): String {
        val assetPath = binding.flutterAssets.getAssetFilePathByName(assetKey)
        val outFile = File(context.cacheDir, "svp_assets/${assetKey.replace('/', '_')}")
        if (!outFile.exists()) {
            outFile.parentFile?.mkdirs()
            context.assets.open(assetPath).use { input ->
                outFile.outputStream().use { input.copyTo(it) }
            }
        }
        return outFile.absolutePath
    }

    private fun instance(playerId: Long): PlayerInstance =
        players[playerId] ?: throw FlutterError(SvpProtocol.ERROR_DISPOSED, "No player $playerId")

    override fun dispose(playerId: Long) {
        players.remove(playerId)?.dispose()
        eventChannels.remove(playerId)?.setStreamHandler(null)
    }

    override fun play(playerId: Long) = instance(playerId).play()
    override fun pause(playerId: Long) = instance(playerId).pause()
    override fun seekTo(playerId: Long, positionMs: Long) =
        instance(playerId).seekTo(positionMs)

    override fun setSpeed(playerId: Long, speed: Double) = instance(playerId).setSpeed(speed)
    override fun setLooping(playerId: Long, looping: Boolean) =
        instance(playerId).setLooping(looping)

    override fun setVolume(playerId: Long, volume: Double) = instance(playerId).setVolume(volume)
    override fun getPosition(playerId: Long): Long = instance(playerId).player.currentPosition

    override fun getTracks(playerId: Long, type: String): List<TrackInfo> =
        instance(playerId).getTracks(type)

    override fun selectTrack(playerId: Long, type: String, trackId: String?) =
        instance(playerId).selectTrack(type, trackId)

    override fun addExternalSubtitle(
        playerId: Long, path: String, mimeType: String, language: String?
    ) = instance(playerId).addExternalSubtitle(path, mimeType, language)

    override fun enterPictureInPicture(playerId: Long): Boolean =
        instance(playerId).enterPictureInPicture()

    override fun setBackgroundPlayback(playerId: Long, enabled: Boolean) =
        instance(playerId).setBackgroundPlayback(enabled)

    override fun configureMediaControls(playerId: Long, config: MediaControlsConfig) =
        instance(playerId).configureMediaControls(config)

    override fun setKeepScreenAwake(enabled: Boolean) {
        val act = activity
        if (act == null) {
            Log.w(TAG, "setKeepScreenAwake($enabled) ignored: no activity attached")
            return
        }
        // Pigeon calls arrive on the main thread; runOnUiThread keeps the window
        // flag mutation on it regardless.
        act.runOnUiThread {
            val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            if (enabled) act.window.addFlags(flag) else act.window.clearFlags(flag)
        }
    }

    override fun setSecureFlag(enabled: Boolean) {
        val window = activity?.window ?: return
        if (enabled) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun getMediaInfo(
        path: String,
        schemeType: String,
        schemeParams: Map<String?, Any?>,
    ): MediaInfo {
        if (!CipherRegistry.isRegistered(schemeType)) {
            throw FlutterError(SvpProtocol.ERROR_ADAPTER_NOT_REGISTERED,
                "No CipherAdapter registered for '$schemeType'")
        }
        return MediaInfoProbe.probe(
            path, schemeType,
            schemeParams.entries.associate { (k, v) -> (k ?: "") to v },
        )
    }

    override fun setScreenBrightness(brightness: Double) {
        val window = activity?.window ?: return
        val attrs = window.attributes
        attrs.screenBrightness =
            if (brightness < 0) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            else brightness.toFloat().coerceIn(0f, 1f)
        window.attributes = attrs
    }

    override fun getScreenBrightness(): Double {
        val brightness = activity?.window?.attributes?.screenBrightness ?: -1f
        return brightness.toDouble()
    }

    override fun startCrypto(
        inputPath: String,
        outputPath: String,
        schemeType: String,
        schemeParams: Map<String?, Any?>,
        encrypt: Boolean,
    ): String {
        if (schemeType == SvpProtocol.SCHEME_CLEAR_KEY) {
            throw FlutterError(SvpProtocol.ERROR_PLATFORM_NOT_SUPPORTED,
                "clearKey content is packaged with CENC tooling, not by this encryptor")
        }
        val adapter = try {
            CipherRegistry.create(
                schemeType,
                schemeParams.entries.associate { (k, v) -> (k ?: "") to v },
            )
        } catch (e: IllegalArgumentException) {
            throw FlutterError(SvpProtocol.ERROR_ADAPTER_NOT_REGISTERED, e.message ?: schemeType)
        }
        return FileCryptor.start(inputPath, outputPath, adapter, encrypt) { p ->
            cryptoEvents.success(mapOf(
                SvpProtocol.KEY_OPERATION_ID to p.operationId,
                SvpProtocol.KEY_BYTES_PROCESSED to p.bytesProcessed,
                SvpProtocol.KEY_TOTAL_BYTES to p.totalBytes,
                SvpProtocol.KEY_DONE to p.done,
                SvpProtocol.KEY_ERROR to p.error,
                SvpProtocol.KEY_ERROR_CODE to p.errorCode,
            ).filterValues { it != null })
        }
    }

    override fun cancelCrypto(operationId: String) = FileCryptor.cancel(operationId)
}

/** PlatformView wrapping a Media3 PlayerView with native controls. */
@UnstableApi
class PlayerPlatformViewFactory(
    private val players: Map<Long, PlayerInstance>,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val playerId = ((args as? Map<*, *>)?.get(SvpProtocol.KEY_PLAYER_ID) as? Number)?.toLong()
        val playerView = PlayerView(context).apply {
            setBackgroundColor(android.graphics.Color.BLACK)
            useController = true
            setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
            player = playerId?.let { players[it]?.player }
        }
        return object : PlatformView {
            override fun getView(): View = playerView
            override fun dispose() {
                playerView.player = null
            }
        }
    }
}

package com.hulkenstein.secure_video_player

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Rational
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.FileDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.LocalMediaDrmCallback
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.source.SingleSampleMediaSource
import androidx.media3.session.MediaSession
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry
import org.json.JSONArray
import org.json.JSONObject

/** Event sink that buffers events until the Dart listener attaches. */
class QueuingEventSink : EventChannel.EventSink {
    private var delegate: EventChannel.EventSink? = null
    private val queue = ArrayDeque<Any>()
    private var done = false

    fun setDelegate(sink: EventChannel.EventSink?) {
        delegate = sink
        while (sink != null && queue.isNotEmpty()) sink.success(queue.removeFirst())
    }

    override fun success(event: Any?) {
        if (done) return
        val d = delegate
        if (d != null) mainThread { d.success(event) } else queue.addLast(event!!)
    }

    override fun error(code: String, message: String?, details: Any?) {
        if (done) return
        mainThread { delegate?.error(code, message, details) }
    }

    override fun endOfStream() {
        done = true
        mainThread { delegate?.endOfStream() }
    }

    private fun mainThread(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else Handler(Looper.getMainLooper()).post(block)
    }
}

/**
 * One native player. Owns an ExoPlayer, an optional Flutter texture surface,
 * its event channel sink, and an optional MediaSession for background audio.
 */
@UnstableApi
class PlayerInstance(
    private val context: Context,
    val playerId: Long,
    private val request: CreateRequest,
    private val surfaceProducer: TextureRegistry.SurfaceProducer?,
    private val activityProvider: () -> Activity?,
) : Player.Listener {

    val events = QueuingEventSink()
    val player: ExoPlayer
    var backgroundPlayback = false
        private set
    var wasPlayingBeforeBackground = false

    private var mediaSession: MediaSession? = null
    private var initializedSent = false
    private val subtitles = mutableListOf<MediaItem.SubtitleConfiguration>()
    private val handler = Handler(Looper.getMainLooper())
    private val positionTicker = object : Runnable {
        override fun run() {
            sendPosition()
            handler.postDelayed(this, 250)
        }
    }

    private val videoFilePath: String = request.source
    private val adapterName: String = request.schemeType
    private val adapterParams: Map<String, Any?> =
        request.schemeParams.entries.associate { (k, v) -> (k ?: "") to v }

    init {
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                request.minBufferMs.toInt(),
                request.maxBufferMs.toInt(),
                request.bufferForPlaybackMs.toInt(),
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
            )
            .setBackBuffer(0, false)
            .build()

        player = ExoPlayer.Builder(context)
            .setLoadControl(loadControl)
            .setSeekBackIncrementMs(5000)
            .setSeekForwardIncrementMs(5000)
            .build()

        player.addListener(this)
        surfaceProducer?.let { player.setVideoSurface(it.surface) }

        player.setMediaSource(buildMediaSource())
        player.repeatMode = if (request.looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        player.volume = request.volume.toFloat()
        if (request.startPositionMs > 0) player.seekTo(request.startPositionMs)
        player.playWhenReady = request.autoPlay
        player.prepare()
    }

    // ---- media source ----

    private fun buildMediaSource(): MediaSource {
        if (adapterName == "clearKey") return buildClearKeySource()

        if (adapterName == "none" && request.sourceType == "url") {
            // Plain streaming (HTTP progressive / HLS / DASH via sniffing).
            return DefaultMediaSourceFactory(DefaultDataSource.Factory(context))
                .createMediaSource(MediaItem.fromUri(request.source))
        }

        val factory = CipherDataSource.Factory(videoFilePath) {
            CipherRegistry.create(adapterName, adapterParams)
        }
        val videoSource = ProgressiveMediaSource.Factory(factory)
            .createMediaSource(MediaItem.fromUri(Uri.fromFile(java.io.File(videoFilePath))))
        return mergeWithSubtitles(videoSource)
    }

    private fun mergeWithSubtitles(video: MediaSource): MediaSource {
        if (subtitles.isEmpty()) return video
        // Subtitle files are plaintext — load them with a plain FileDataSource,
        // never through the video's cipher.
        val subFactory = SingleSampleMediaSource.Factory(FileDataSource.Factory())
        val sources = mutableListOf(video)
        subtitles.forEach { sources.add(subFactory.createMediaSource(it, C.TIME_UNSET)) }
        return MergingMediaSource(*sources.toTypedArray())
    }

    private fun buildClearKeySource(): MediaSource {
        val keys = adapterParams["keys"] as? Map<*, *>
            ?: throw IllegalArgumentException("clearKey requires 'keys' map")
        val jwks = JSONObject().apply {
            put("keys", JSONArray().apply {
                keys.forEach { (kid, k) ->
                    put(JSONObject().apply {
                        put("kty", "oct")
                        put("kid", kid.toString())
                        put("k", k.toString())
                    })
                }
            })
            put("type", "temporary")
        }
        val drmCallback = LocalMediaDrmCallback(jwks.toString().toByteArray())
        val drmManager = DefaultDrmSessionManager.Builder()
            .setUuidAndExoMediaDrmProvider(C.CLEARKEY_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
            .build(drmCallback)

        val uri = if (request.sourceType == "url") Uri.parse(request.source)
        else Uri.fromFile(java.io.File(request.source))
        val dataFactory = DefaultDataSource.Factory(context)
        val item = MediaItem.fromUri(uri)
        return if (request.source.endsWith(".mpd") ) {
            DashMediaSource.Factory(dataFactory)
                .setDrmSessionManagerProvider { drmManager }
                .createMediaSource(item)
        } else {
            ProgressiveMediaSource.Factory(dataFactory)
                .setDrmSessionManagerProvider { drmManager }
                .createMediaSource(item)
        }
    }

    // ---- Player.Listener ----

    override fun onPlaybackStateChanged(state: Int) {
        when (state) {
            Player.STATE_READY -> {
                if (!initializedSent) {
                    initializedSent = true
                    val size = player.videoSize
                    events.success(mapOf(
                        "event" to "initialized",
                        "duration" to maxOf(0L, player.duration),
                        "width" to size.width,
                        "height" to size.height,
                    ))
                    handler.post(positionTicker)
                } else {
                    events.success(mapOf("event" to "ready"))
                }
            }
            Player.STATE_BUFFERING -> events.success(mapOf("event" to "buffering"))
            Player.STATE_ENDED -> events.success(mapOf("event" to "completed"))
            else -> {}
        }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        events.success(mapOf("event" to "isPlayingChanged", "isPlaying" to isPlaying))
        sendPosition()
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.width > 0 && videoSize.height > 0) {
            events.success(mapOf(
                "event" to "videoSize",
                "width" to videoSize.width,
                "height" to videoSize.height,
            ))
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        val code = when {
            error.errorCode == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> "fileNotFound"
            error.errorCode in PlaybackException.ERROR_CODE_DRM_UNSPECIFIED..
                PlaybackException.ERROR_CODE_DRM_LICENSE_EXPIRED -> "drmError"
            error.errorCode in PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED..
                PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED -> "corruptStream"
            else -> "unknown"
        }
        events.success(mapOf(
            "event" to "error",
            "code" to code,
            "message" to (error.message ?: "Playback error"),
        ))
    }

    private fun sendPosition() {
        events.success(mapOf(
            "event" to "position",
            "position" to player.currentPosition,
            "buffered" to player.bufferedPosition,
        ))
    }

    // ---- controls ----

    fun play() {
        if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
        player.play()
    }

    fun pause() = player.pause()
    fun seekTo(positionMs: Long) = player.seekTo(positionMs)
    fun setSpeed(speed: Double) = player.setPlaybackSpeed(speed.toFloat())
    fun setVolume(volume: Double) { player.volume = volume.toFloat() }

    fun setLooping(looping: Boolean) {
        player.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    // ---- tracks ----

    private fun trackTypeOf(type: String): Int = when (type) {
        "audio" -> C.TRACK_TYPE_AUDIO
        "subtitle" -> C.TRACK_TYPE_TEXT
        "video" -> C.TRACK_TYPE_VIDEO
        else -> throw IllegalArgumentException("Unknown track type: $type")
    }

    fun getTracks(type: String): List<TrackInfo> {
        val trackType = trackTypeOf(type)
        val result = mutableListOf<TrackInfo>()
        player.currentTracks.groups.forEachIndexed { groupIndex, group ->
            if (group.type != trackType) return@forEachIndexed
            for (i in 0 until group.length) {
                val format = group.getTrackFormat(i)
                result.add(TrackInfo(
                    id = "$groupIndex:$i",
                    type = type,
                    selected = group.isTrackSelected(i),
                    label = format.label,
                    language = format.language,
                    width = format.width.takeIf { it > 0 }?.toLong(),
                    height = format.height.takeIf { it > 0 }?.toLong(),
                    bitrate = format.bitrate.takeIf { it > 0 }?.toLong(),
                ))
            }
        }
        return result
    }

    fun selectTrack(type: String, trackId: String?) {
        val trackType = trackTypeOf(type)
        val builder = player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(trackType)
        if (trackId == null) {
            // Off for subtitles, auto for audio/video.
            builder.setTrackTypeDisabled(trackType, type == "subtitle")
        } else {
            val (groupIndex, trackIndex) = trackId.split(":").map { it.toInt() }
            val group = player.currentTracks.groups[groupIndex]
            builder.setTrackTypeDisabled(trackType, false)
            builder.addOverride(TrackSelectionOverride(group.mediaTrackGroup, trackIndex))
        }
        player.trackSelectionParameters = builder.build()
    }

    fun addExternalSubtitle(path: String, mimeType: String, language: String?) {
        val mime = when {
            mimeType.isNotBlank() -> mimeType
            path.endsWith(".srt") -> MimeTypes.APPLICATION_SUBRIP
            else -> MimeTypes.TEXT_VTT
        }
        subtitles.add(
            MediaItem.SubtitleConfiguration.Builder(Uri.fromFile(java.io.File(path)))
                .setMimeType(mime)
                .setLanguage(language)
                .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                .build()
        )
        // Rebuild the merged source, preserving position and play state.
        val position = player.currentPosition
        val wasPlaying = player.isPlaying
        player.setMediaSource(buildMediaSource())
        player.prepare()
        player.seekTo(position)
        player.playWhenReady = wasPlaying
    }

    // ---- PiP / background / lifecycle ----

    fun enterPictureInPicture(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val activity = activityProvider() ?: return false
        val size = player.videoSize
        val ratio = if (size.width > 0 && size.height > 0)
            Rational(size.width, size.height) else Rational(16, 9)
        return try {
            activity.enterPictureInPictureMode(
                PictureInPictureParams.Builder().setAspectRatio(ratio).build())
            events.success(mapOf("event" to "pipChanged", "active" to true))
            true
        } catch (e: IllegalStateException) {
            false
        }
    }

    fun setBackgroundPlayback(enabled: Boolean) {
        backgroundPlayback = enabled
        if (enabled && mediaSession == null) {
            // ponytail: MediaSession gives lock-screen/media-button controls;
            // add a MediaSessionService + foreground notification if playback
            // must survive aggressive process death.
            mediaSession = MediaSession.Builder(context, player)
                .setId("secure_video_player_$playerId")
                .build()
        } else if (!enabled) {
            mediaSession?.release()
            mediaSession = null
        }
    }

    fun dispose() {
        handler.removeCallbacks(positionTicker)
        mediaSession?.release()
        mediaSession = null
        player.removeListener(this)
        player.stop()
        player.clearVideoSurface()
        player.release()
        surfaceProducer?.release()
        events.endOfStream()
    }
}

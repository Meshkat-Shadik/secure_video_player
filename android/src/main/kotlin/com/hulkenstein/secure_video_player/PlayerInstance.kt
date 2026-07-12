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
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.FileDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.LocalMediaDrmCallback
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.source.SingleSampleMediaSource
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.text.TextRenderer
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
    private var mediaControlsEnabled = false
    private var mediaControlsConfig: MediaControlsConfig? = null
    private var initializedSent = false
    private var lastPipActive = false
    private val subtitles = mutableListOf<MediaItem.SubtitleConfiguration>()
    private data class TrackRestoreState(
        val selectedTrackId: String?,
        val disabled: Boolean,
    )
    private var pendingTrackRestore: Map<String, TrackRestoreState>? = null
    private val handler = Handler(Looper.getMainLooper())
    private var tickerRunning = false
    private val positionTicker = object : Runnable {
        override fun run() {
            sendPosition()
            checkPipState()
            handler.postDelayed(this, 250)
        }
    }

    // Gate the ticker on playback: a paused/ended player emits no position
    // events (perf P1). startTicker guards against double-posting.
    private fun startTicker() {
        if (tickerRunning) return
        tickerRunning = true
        handler.post(positionTicker)
    }

    private fun stopTicker() {
        tickerRunning = false
        handler.removeCallbacks(positionTicker)
    }

    // Lightweight PiP poll, independent of the position ticker (which stops
    // while paused). Without it, pausing inside PiP then closing the window
    // would emit no pipChanged(false). Runs only while PiP is active.
    private var pipPollRunning = false
    private val pipPoller = object : Runnable {
        override fun run() {
            checkPipState()
            if (pipPollRunning) handler.postDelayed(this, 500)
        }
    }

    private fun startPipPoll() {
        if (pipPollRunning) return
        pipPollRunning = true
        handler.postDelayed(pipPoller, 500)
    }

    private fun stopPipPoll() {
        pipPollRunning = false
        handler.removeCallbacks(pipPoller)
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

        // Sideloaded subtitles (SingleSampleMediaSource) deliver raw text/vtt
        // and text/x-subrip samples to the TextRenderer. Since media3 1.4 the
        // renderer parses subtitles during extraction by default and refuses
        // legacy samples ("Legacy decoding is disabled, can't handle text/vtt")
        // unless legacy decoding is enabled. In 1.10 that flag lives on
        // TextRenderer itself (not DefaultRenderersFactory), so enable it on
        // each text renderer the factory builds. Container-embedded subs parse
        // during extraction and are unaffected.
        val renderersFactory = object : DefaultRenderersFactory(context) {
            override fun buildTextRenderers(
                context: Context,
                output: TextOutput,
                outputLooper: Looper,
                extensionRendererMode: Int,
                out: ArrayList<Renderer>,
            ) {
                super.buildTextRenderers(
                    context, output, outputLooper, extensionRendererMode, out)
                out.forEach { if (it is TextRenderer) it.experimentalSetLegacyDecodingEnabled(true) }
            }
        }

        player = ExoPlayer.Builder(context, renderersFactory)
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

    /**
     * Builds the source MediaItem, baking in the media-controls metadata
     * (title/artist/artwork) when set so the system notification and lock screen
     * show it. The item is created here, not via replaceMediaItem, so playback
     * keeps using the custom CipherDataSource factory.
     */
    private fun mediaItemFor(uri: Uri): MediaItem {
        val c = mediaControlsConfig
        if (c == null || (c.title == null && c.artist == null && c.artworkPath == null)) {
            return MediaItem.fromUri(uri)
        }
        val metadata = MediaMetadata.Builder().apply {
            c.title?.let { setTitle(it) }
            c.artist?.let { setArtist(it) }
            c.artworkPath?.let { setArtworkUri(Uri.fromFile(java.io.File(it))) }
        }.build()
        return MediaItem.Builder().setUri(uri).setMediaMetadata(metadata).build()
    }

    private fun buildMediaSource(): MediaSource {
        if (adapterName == SvpProtocol.SCHEME_CLEAR_KEY) return buildClearKeySource()

        if (adapterName == SvpProtocol.SCHEME_NONE && request.sourceType == SvpProtocol.SOURCE_URL) {
            // Plain streaming (HTTP progressive / HLS / DASH via sniffing).
            return DefaultMediaSourceFactory(DefaultDataSource.Factory(context))
                .createMediaSource(mediaItemFor(Uri.parse(request.source)))
        }

        val adapterFactory = { CipherRegistry.create(adapterName, adapterParams) }
        val isContentUri = request.sourceType == SvpProtocol.SOURCE_CONTENT_URI
        val factory = if (isContentUri) {
            CipherDataSource.Factory.forContentUri(context, request.source, adapterFactory)
        } else {
            CipherDataSource.Factory.forFile(videoFilePath, adapterFactory)
        }
        val mediaUri = if (isContentUri) Uri.parse(request.source)
        else Uri.fromFile(java.io.File(videoFilePath))
        val videoSource = ProgressiveMediaSource.Factory(factory)
            .createMediaSource(mediaItemFor(mediaUri))
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

        val uri = if (request.sourceType == SvpProtocol.SOURCE_URL) Uri.parse(request.source)
        else Uri.fromFile(java.io.File(request.source))
        val dataFactory = DefaultDataSource.Factory(context)
        val item = mediaItemFor(uri)
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

    /**
     * Display geometry for the Flutter side: (width, height, rotationCorrection).
     *
     * Media3's MediaCodecVideoRenderer already flips width/height for 90/270
     * rotations before reporting [Player.getVideoSize], so videoSize IS the
     * display size — never swap it again (doing so was the SVP-rotation bug).
     *
     * When the Flutter surface applies the codec's buffer transform
     * (SurfaceProducer.handlesCropAndRotation) the texture already shows the
     * frame upright. Otherwise (ImageReader-backed producers, Impeller default)
     * the texture receives raw unrotated frames and Dart must rotate with a
     * RotatedBox by the track's rotation metadata — mirroring the official
     * video_player plugin's TextureExoPlayerEventListener.
     */
    private fun displayGeometry(): Triple<Int, Int, Int> {
        val size = player.videoSize
        var correction = 0
        val surfaceHandlesRotation = surfaceProducer?.handlesCropAndRotation() ?: true
        if (!surfaceHandlesRotation) {
            val rotation = player.videoFormat?.rotationDegrees ?: 0
            correction = ((rotation % 360) + 360) % 360
        }
        return Triple(size.width, size.height, correction)
    }

    private fun sizeEventPayload(event: String): Map<String, Any> {
        val (width, height, correction) = displayGeometry()
        return mapOf(
            SvpProtocol.EVENT_KEY to event,
            SvpProtocol.KEY_WIDTH to width,
            SvpProtocol.KEY_HEIGHT to height,
            SvpProtocol.KEY_ROTATION_CORRECTION to correction,
        )
    }

    override fun onPlaybackStateChanged(state: Int) {
        when (state) {
            Player.STATE_READY -> {
                restoreTrackSelectionAfterRebuild()
                if (!initializedSent) {
                    initializedSent = true
                    events.success(sizeEventPayload(SvpProtocol.EVENT_INITIALIZED) +
                        mapOf(SvpProtocol.KEY_DURATION to maxOf(0L, player.duration)))
                    // One position snapshot so a paused start (autoPlay=false,
                    // startPositionMs) shows the right position before the ticker
                    // runs; the ticker itself starts on onIsPlayingChanged(true).
                    sendPosition()
                } else {
                    events.success(mapOf(SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_READY))
                }
            }
            Player.STATE_BUFFERING -> events.success(mapOf(SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_BUFFERING))
            Player.STATE_ENDED -> {
                stopTicker()
                events.success(mapOf(SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_COMPLETED))
            }
            Player.STATE_IDLE -> stopTicker()
            else -> {}
        }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        events.success(mapOf(SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_IS_PLAYING_CHANGED, SvpProtocol.KEY_IS_PLAYING to isPlaying))
        if (isPlaying) startTicker() else stopTicker()
        // Final position on pause / immediate position on resume.
        sendPosition()
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.width > 0 && videoSize.height > 0) {
            events.success(sizeEventPayload(SvpProtocol.EVENT_VIDEO_SIZE))
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        val code = when {
            error.errorCode == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> SvpProtocol.ERROR_FILE_NOT_FOUND
            error.errorCode in PlaybackException.ERROR_CODE_DRM_UNSPECIFIED..
                PlaybackException.ERROR_CODE_DRM_LICENSE_EXPIRED -> SvpProtocol.ERROR_DRM
            error.errorCode in PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED..
                PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED -> SvpProtocol.ERROR_CORRUPT_STREAM
            // Decoder failures and reads past EOF (truncated / tampered files)
            // are all "the stream is broken" from the caller's point of view.
            error.errorCode in PlaybackException.ERROR_CODE_DECODING_FAILED..
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> SvpProtocol.ERROR_CORRUPT_STREAM
            error.errorCode == PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE ->
                SvpProtocol.ERROR_CORRUPT_STREAM
            else -> SvpProtocol.ERROR_UNKNOWN
        }
        events.success(mapOf(
            SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_ERROR,
            SvpProtocol.KEY_CODE to code,
            SvpProtocol.KEY_MESSAGE to (error.message ?: "Playback error"),
        ))
    }

    private fun sendPosition() {
        events.success(mapOf(
            SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_POSITION,
            SvpProtocol.KEY_POSITION to player.currentPosition,
            SvpProtocol.KEY_BUFFERED to player.bufferedPosition,
        ))
    }

    // ---- controls ----

    fun play() {
        if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
        player.play()
    }

    fun pause() = player.pause()

    fun seekTo(positionMs: Long) {
        player.seekTo(positionMs)
        // While playing the ticker reports the new position; while paused it is
        // stopped, so push one position event or seek-while-paused wouldn't update.
        if (!player.isPlaying) sendPosition()
    }

    fun setSpeed(speed: Double) = player.setPlaybackSpeed(speed.toFloat())
    fun setVolume(volume: Double) { player.volume = volume.toFloat() }

    fun setLooping(looping: Boolean) {
        player.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    // ---- tracks ----

    private fun trackTypeOf(type: String): Int = when (type) {
        SvpProtocol.TRACK_AUDIO -> C.TRACK_TYPE_AUDIO
        SvpProtocol.TRACK_SUBTITLE -> C.TRACK_TYPE_TEXT
        SvpProtocol.TRACK_VIDEO -> C.TRACK_TYPE_VIDEO
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
            builder.setTrackTypeDisabled(trackType, type == SvpProtocol.TRACK_SUBTITLE)
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
        rebuildSourcePreservingState()
    }

    private fun snapshotTrackRestoreState(type: String): TrackRestoreState {
        val trackType = trackTypeOf(type)
        return TrackRestoreState(
            selectedTrackId = getTracks(type).firstOrNull { it.selected }?.id,
            disabled = player.trackSelectionParameters.disabledTrackTypes.contains(trackType),
        )
    }

    private fun restoreTrackSelectionAfterRebuild() {
        val restore = pendingTrackRestore ?: return
        pendingTrackRestore = null

        restore[SvpProtocol.TRACK_AUDIO]?.selectedTrackId?.let {
            selectTrack(SvpProtocol.TRACK_AUDIO, it)
        }
        restore[SvpProtocol.TRACK_VIDEO]?.selectedTrackId?.let {
            selectTrack(SvpProtocol.TRACK_VIDEO, it)
        }
        restore[SvpProtocol.TRACK_SUBTITLE]?.let { subtitle ->
            when {
                subtitle.selectedTrackId != null ->
                    selectTrack(SvpProtocol.TRACK_SUBTITLE, subtitle.selectedTrackId)
                subtitle.disabled -> {
                    val trackType = trackTypeOf(SvpProtocol.TRACK_SUBTITLE)
                    val builder = player.trackSelectionParameters.buildUpon()
                        .clearOverridesOfType(trackType)
                        .setTrackTypeDisabled(trackType, true)
                    player.trackSelectionParameters = builder.build()
                }
            }
        }
    }

    override fun onTracksChanged(tracks: Tracks) {
        restoreTrackSelectionAfterRebuild()
    }

    /** Rebuilds the media source (subtitles / metadata changes) in place. */
    private fun rebuildSourcePreservingState() {
        pendingTrackRestore = mapOf(
            SvpProtocol.TRACK_AUDIO to snapshotTrackRestoreState(SvpProtocol.TRACK_AUDIO),
            SvpProtocol.TRACK_VIDEO to snapshotTrackRestoreState(SvpProtocol.TRACK_VIDEO),
            SvpProtocol.TRACK_SUBTITLE to snapshotTrackRestoreState(SvpProtocol.TRACK_SUBTITLE),
        )
        val position = player.currentPosition
        // Capture the play INTENT (playWhenReady), not isPlaying: called during
        // BUFFERING, isPlaying is false and would silently un-pause the user.
        val wasPlayWhenReady = player.playWhenReady
        player.setMediaSource(buildMediaSource())
        player.prepare()
        player.seekTo(position)
        player.playWhenReady = wasPlayWhenReady
    }

    // ---- PiP / background / lifecycle ----

    fun enterPictureInPicture(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val activity = activityProvider() ?: return false
        // PiP aspect must be the DISPLAY shape (rotation applied) and inside
        // Android's allowed 1:2.39 range, or enterPictureInPictureMode throws.
        val (width, height, _) = displayGeometry()
        var ratio = if (width > 0 && height > 0) Rational(width, height) else Rational(16, 9)
        if (ratio.toFloat() < 1 / 2.39f) ratio = Rational(100, 239)
        if (ratio.toFloat() > 2.39f) ratio = Rational(239, 100)
        return try {
            val entered = activity.enterPictureInPictureMode(
                PictureInPictureParams.Builder().setAspectRatio(ratio).build())
            if (entered) {
                lastPipActive = true
                startPipPoll()
                events.success(mapOf(SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_PIP_CHANGED, SvpProtocol.KEY_ACTIVE to true))
            }
            entered
        } catch (e: IllegalStateException) {
            // Missing android:supportsPictureInPicture="true" on the activity.
            false
        }
    }

    /** Ticker-driven: detects the user closing/expanding the PiP window. */
    private fun checkPipState() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val active = activityProvider()?.isInPictureInPictureMode ?: false
        if (active != lastPipActive) {
            lastPipActive = active
            events.success(mapOf(SvpProtocol.EVENT_KEY to SvpProtocol.EVENT_PIP_CHANGED, SvpProtocol.KEY_ACTIVE to active))
            if (active) startPipPoll() else stopPipPoll()
        }
    }

    fun setBackgroundPlayback(enabled: Boolean) {
        backgroundPlayback = enabled
        if (enabled) ensureMediaSession() else maybeReleaseMediaSession()
    }

    /**
     * Enables/disables system media controls (foreground notification + lock
     * screen). Shares the single [mediaSession] with background playback via
     * [ensureMediaSession]; the [PlaybackService] posts the notification.
     * `enabled = false` removes the notification and releases the session iff
     * background playback no longer needs it.
     */
    fun configureMediaControls(config: MediaControlsConfig) {
        if (config.enabled) {
            mediaControlsEnabled = true
            mediaControlsConfig = config
            // Bake title/artist/artwork into the loaded item so the notification
            // shows it (only reprepares when there is metadata to apply).
            if (config.title != null || config.artist != null || config.artworkPath != null) {
                rebuildSourcePreservingState()
            }
            ensureMediaSession()
            PlaybackService.enable(context, playerId, mediaSession!!)
        } else {
            mediaControlsEnabled = false
            mediaControlsConfig = null
            PlaybackService.disable(context, playerId)
            maybeReleaseMediaSession()
        }
    }

    /** One MediaSession per player, shared by background playback + controls. */
    private fun ensureMediaSession() {
        if (mediaSession == null) {
            mediaSession = MediaSession.Builder(context, player)
                .setId("secure_video_player_$playerId")
                .build()
        }
    }

    private fun maybeReleaseMediaSession() {
        if (backgroundPlayback || mediaControlsEnabled) return
        mediaSession?.release()
        mediaSession = null
    }

    fun dispose() {
        handler.removeCallbacks(positionTicker)
        stopPipPoll()
        // Remove this player's notification and stop the service if it was last.
        PlaybackService.disable(context, playerId)
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

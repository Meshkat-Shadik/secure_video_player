package com.hulkenstein.secure_video_player

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Foreground [MediaSessionService] that hosts a real media notification
 * (play/pause/seek from the notification shade and lock screen) for players that
 * enabled system media controls via `configureMediaControls`.
 *
 * The ExoPlayer + [MediaSession] are owned by [PlayerInstance] — exactly one
 * MediaSession per player, shared with background playback. This service never
 * creates them; it only [addSession]s the externally-owned sessions so media3
 * posts and manages their notifications and promotes itself to foreground while
 * playing.
 *
 * POST_NOTIFICATIONS (Android 13+): the host app must request this runtime
 * permission itself for the notification to be visible. This plugin declares the
 * FOREGROUND_SERVICE and FOREGROUND_SERVICE_MEDIA_PLAYBACK permissions it needs
 * but deliberately does NOT request POST_NOTIFICATIONS — that runtime prompt is
 * a host-app UX decision.
 */
@UnstableApi
class PlaybackService : MediaSessionService() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        // Attach sessions registered before the service finished starting.
        registry.values.forEach { addSession(it) }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        registry.values.firstOrNull()

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "SvpPlaybackService"

        // playerId -> session that currently wants a media notification.
        private val registry = mutableMapOf<Long, MediaSession>()
        private var instance: PlaybackService? = null

        /** Show a media notification for [session] and ensure the service is up. */
        fun enable(context: Context, playerId: Long, session: MediaSession) {
            registry[playerId] = session
            instance?.addSession(session)
            val intent = Intent(context, PlaybackService::class.java)
            try {
                // Must be started while the app is foregrounded (configureMediaControls
                // is a Dart call, so it is). media3 promotes itself to foreground with
                // the mediaPlayback notification once playback is active.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ ForegroundServiceStartNotAllowedException (a media FGS may
                // only start from the foreground) and kin — log, never crash. Controls
                // just won't appear until the next foreground configure call.
                Log.w(TAG, "startForegroundService failed for player $playerId: ${e.message}")
            }
        }

        /** Remove [playerId]'s notification; stop the service when none remain. */
        fun disable(context: Context, playerId: Long) {
            registry.remove(playerId)?.let { instance?.removeSession(it) }
            if (registry.isEmpty()) {
                context.stopService(Intent(context, PlaybackService::class.java))
            }
        }
    }
}

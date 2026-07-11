package com.hulkenstein.secure_video_player

import android.media.MediaDataSource
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.RandomAccessFile

/**
 * Probes container + per-stream metadata (MX-Player-style info panel) from a
 * possibly encrypted file. Bytes are decrypted on the fly through the same
 * [CipherAdapter] used for playback, so ciphertext never hits a temp file.
 */
object MediaInfoProbe {

    /** MediaDataSource that decrypts each read via the adapter (API 23+). */
    private class CipherMediaDataSource(
        path: String,
        private val adapter: CipherAdapter,
    ) : MediaDataSource() {
        private val file = RandomAccessFile(path, "r")
        private val length = file.length()

        override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
            if (position >= length) return -1
            synchronized(file) {
                file.seek(position)
                // Clamp as Long first: (length - position) overflows Int for
                // files with >2GiB remaining, yielding a negative read length.
                val read = file.read(buffer, offset, minOf(size.toLong(), length - position).toInt())
                if (read > 0) adapter.transform(buffer, offset, read, position)
                return read
            }
        }

        override fun getSize(): Long = length
        override fun close() = file.close()
    }

    fun probe(path: String, schemeType: String, schemeParams: Map<String, Any?>): MediaInfo {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            throw FlutterError(SvpProtocol.ERROR_PLATFORM_NOT_SUPPORTED,
                "getMediaInfo needs Android 6.0+ (MediaDataSource)")
        }
        if (!java.io.File(path).exists()) {
            throw FlutterError(SvpProtocol.ERROR_FILE_NOT_FOUND, "File not found: $path")
        }

        val streams = mutableListOf<MediaStreamInfo>()
        var durationMs = 0L

        val extractor = MediaExtractor()
        val extractorSource = CipherMediaDataSource(path, CipherRegistry.create(schemeType, schemeParams))
        try {
            extractor.setDataSource(extractorSource)
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getStringOrNull(MediaFormat.KEY_MIME) ?: "unknown"
                durationMs = maxOf(durationMs, (f.getLongOrNull(MediaFormat.KEY_DURATION) ?: 0L) / 1000)
                streams.add(MediaStreamInfo(
                    type = when {
                        mime.startsWith("video/") -> "video"
                        mime.startsWith("audio/") -> "audio"
                        mime.startsWith("text/") || mime.startsWith("application/") -> "subtitle"
                        else -> "unknown"
                    },
                    codec = mime,
                    profile = profileString(f),
                    width = f.getIntOrNull(MediaFormat.KEY_WIDTH)?.toLong(),
                    height = f.getIntOrNull(MediaFormat.KEY_HEIGHT)?.toLong(),
                    frameRate = f.getNumberOrNull(MediaFormat.KEY_FRAME_RATE),
                    bitrate = f.getIntOrNull(MediaFormat.KEY_BIT_RATE)?.toLong(),
                    sampleRate = f.getIntOrNull(MediaFormat.KEY_SAMPLE_RATE)?.toLong(),
                    channels = f.getIntOrNull(MediaFormat.KEY_CHANNEL_COUNT)?.toLong(),
                    language = f.getStringOrNull(MediaFormat.KEY_LANGUAGE)
                        ?.takeIf { it.isNotEmpty() && it != "und" },
                ))
            }
        } catch (e: Exception) {
            throw FlutterError(SvpProtocol.ERROR_CORRUPT_STREAM,
                "Cannot probe media: ${e.message}")
        } finally {
            extractor.release()
            extractorSource.close()
        }

        var container: String? = null
        var rotation: Long? = null
        var totalBitrate: Long? = null
        val retriever = MediaMetadataRetriever()
        val retrieverSource = CipherMediaDataSource(path, CipherRegistry.create(schemeType, schemeParams))
        try {
            retriever.setDataSource(retrieverSource)
            container = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            rotation = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toLongOrNull()
            totalBitrate = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()
            if (durationMs == 0L) {
                durationMs = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            }
        } catch (_: Exception) {
            // Container-level extras are best effort; stream info already set.
        } finally {
            retriever.release()
            retrieverSource.close()
        }

        return MediaInfo(
            durationMs = durationMs,
            container = container,
            rotation = rotation,
            bitrate = totalBitrate,
            streams = streams,
        )
    }

    /** "profile 2 · level 65536" — raw codec ints; codec-specific name tables
     *  aren't worth their weight here. */
    private fun profileString(f: MediaFormat): String? {
        val profile = f.getIntOrNull(MediaFormat.KEY_PROFILE) ?: return null
        val level = f.getIntOrNull(MediaFormat.KEY_LEVEL)
        return if (level != null) "profile $profile · level $level" else "profile $profile"
    }

    private fun MediaFormat.getIntOrNull(key: String): Int? =
        if (containsKey(key)) getInteger(key) else null

    private fun MediaFormat.getLongOrNull(key: String): Long? =
        if (containsKey(key)) getLong(key) else null

    private fun MediaFormat.getStringOrNull(key: String): String? =
        if (containsKey(key)) getString(key) else null

    /** KEY_FRAME_RATE may be stored as int or float depending on the muxer. */
    private fun MediaFormat.getNumberOrNull(key: String): Double? {
        if (!containsKey(key)) return null
        return try {
            getInteger(key).toDouble()
        } catch (_: Exception) {
            try {
                getFloat(key).toDouble()
            } catch (_: Exception) {
                null
            }
        }
    }
}

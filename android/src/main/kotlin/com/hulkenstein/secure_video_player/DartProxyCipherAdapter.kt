package com.hulkenstein.secure_video_player

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.BinaryMessenger
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Built-in adapter that proxies each read chunk to a pure-Dart
 * `DartCipherDelegate` over a dedicated BasicMessageChannel (BinaryCodec),
 * named `secure_video_player/dart_cipher_<channelId>`.
 *
 * Request frame: [1B direction: 0=decrypt, 1=encrypt][8B file offset, big-endian][payload].
 * Reply: transformed bytes (same length); null/short/timeout -> IOException.
 *
 * Threading: transform() is called on a background reader (ExoPlayer's load
 * thread, FileCryptor's executor, or a probe thread) — never the main thread.
 * BinaryMessenger.send must run on the platform (main) thread, so we post the
 * send to the main looper and block the caller thread on a latch. The main
 * thread stays free to deliver Dart's reply, so there is no deadlock. If
 * transform() is ever called ON the main thread we fail fast instead of
 * deadlocking against ourselves.
 */
class DartProxyCipherAdapter(
    private val messenger: BinaryMessenger,
) : CipherAdapter {

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var channel: BasicMessageChannel<ByteBuffer>
    private var timeoutMs = 5000L

    override fun init(params: Map<String, Any?>) {
        val channelId = params["channelId"] as? String
            ?: throw IllegalArgumentException("dartProxy requires a 'channelId' string")
        (params["timeoutMs"] as? Number)?.let { timeoutMs = it.toLong() }
        channel = BasicMessageChannel(
            messenger,
            "${SvpProtocol.CHANNEL_DART_CIPHER_PREFIX}$channelId",
            BinaryCodec.INSTANCE,
        )
    }

    override fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long) =
        transform(buffer, offset, length, filePosition, encrypt = false)

    override fun transform(
        buffer: ByteArray, offset: Int, length: Int, filePosition: Long, encrypt: Boolean,
    ) {
        if (length <= 0) return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw IOException(
                "DartProxyCipherAdapter.transform called on the main thread; " +
                    "this would deadlock. Dart ciphers only work on background readers " +
                    "(playback / file encrypt); getMediaInfo may probe on the main thread.",
            )
        }

        // Frame: [dir: 0=decrypt, 1=encrypt][offset 8B BE][payload]. Direct buffer required by send().
        val request = ByteBuffer.allocateDirect(9 + length).order(ByteOrder.BIG_ENDIAN)
        request.put(if (encrypt) 1 else 0)
        request.putLong(filePosition)
        request.put(buffer, offset, length)
        request.flip()

        val latch = CountDownLatch(1)
        val reply = arrayOfNulls<ByteBuffer>(1)
        mainHandler.post {
            channel.send(request) { response ->
                reply[0] = response
                latch.countDown()
            }
        }

        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            throw IOException("Dart cipher timed out after ${timeoutMs}ms")
        }
        val response = reply[0]
            ?: throw IOException("Dart cipher delegate returned an error or no data")
        if (response.remaining() != length) {
            throw IOException(
                "Dart cipher returned ${response.remaining()} bytes, expected $length",
            )
        }
        response.get(buffer, offset, length)
    }
}

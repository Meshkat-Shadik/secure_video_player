package com.hulkenstein.secure_video_player

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/** An opened, seekable read channel plus its byte size and anything to close. */
class ChannelHandle(
    val channel: FileChannel,
    val size: Long,
    private val extra: Closeable?,
) : Closeable {
    override fun close() {
        try {
            channel.close()
        } finally {
            extra?.close()
        }
    }
}

/**
 * Media3 DataSource that reads an encrypted source and decrypts each chunk in
 * place through a [CipherAdapter]. Ciphertext is read directly into ExoPlayer's
 * target array (reads capped at 64 KB) and decrypted in place — no intermediate
 * copy, constant memory regardless of file size. The source is a local file path OR an
 * Android `content://` URI (MediaStore gallery file edited in place), both
 * seekable regular files.
 */
@UnstableApi
class CipherDataSource(
    private val opener: () -> ChannelHandle,
    private val adapter: CipherAdapter,
) : DataSource {

    companion object {
        private const val BUFFER_SIZE = 64 * 1024
    }

    private var handle: ChannelHandle? = null
    private var channel: FileChannel? = null
    private var uri: Uri? = null
    private var position = 0L
    private var bytesRemaining = 0L
    private var opened = false

    @Throws(IOException::class)
    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        val h = opener()
        handle = h
        channel = h.channel

        position = dataSpec.position
        if (position > 0) channel!!.position(position)

        bytesRemaining = if (dataSpec.length == C.LENGTH_UNSET.toLong()) {
            adapter.plaintextSize(h.size) - position
        } else {
            dataSpec.length
        }
        // A truncated file makes the extractor seek past EOF (e.g. an MP4 whose
        // moov atom was cut off). Throw the typed exception so ExoPlayer reports
        // ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE instead of a generic IO error,
        // which onPlayerError maps to corruptStream.
        if (bytesRemaining < 0) {
            throw DataSourceException(
                "Position beyond end of source",
                DataSourceException.POSITION_OUT_OF_RANGE,
            )
        }
        opened = true
        return bytesRemaining
    }

    @Throws(IOException::class)
    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (!opened) throw IOException("DataSource not opened")
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT

        val toRead = minOf(length.toLong(), bytesRemaining, BUFFER_SIZE.toLong()).toInt()
        // Read ciphertext straight into ExoPlayer's array, then decrypt in place
        // — no intermediate buffer copy. channel.read may return fewer bytes
        // than requested; we decrypt exactly what was read at this file position.
        val read = channel!!.read(ByteBuffer.wrap(target, offset, toRead))
        if (read == -1) return C.RESULT_END_OF_INPUT

        adapter.transform(target, offset, read, position)

        position += read
        bytesRemaining -= read
        return read
    }

    override fun getUri(): Uri? = uri

    @Throws(IOException::class)
    override fun close() {
        opened = false
        try {
            handle?.close()
        } finally {
            handle = null
            channel = null
        }
    }

    override fun addTransferListener(transferListener: TransferListener) {
        // Local reads; transfer stats not reported.
    }

    class Factory private constructor(
        private val opener: () -> ChannelHandle,
        private val adapterFactory: () -> CipherAdapter,
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource =
            CipherDataSource(opener, adapterFactory())

        companion object {
            /** Encrypted local file. */
            fun forFile(filePath: String, adapterFactory: () -> CipherAdapter) =
                Factory({
                    val f = File(filePath)
                    if (!f.exists()) throw IOException("Encrypted file not found: $filePath")
                    val raf = RandomAccessFile(f, "r")
                    ChannelHandle(raf.channel, f.length(), raf)
                }, adapterFactory)

            /** Encrypted MediaStore `content://` file, read via the resolver. */
            fun forContentUri(
                context: Context,
                uriString: String,
                adapterFactory: () -> CipherAdapter,
            ) = Factory({
                val pfd = context.contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                    ?: throw IOException("Cannot open content uri: $uriString")
                val fis = FileInputStream(pfd.fileDescriptor)
                // Close both the stream and the descriptor when done.
                ChannelHandle(fis.channel, pfd.statSize, Closeable {
                    try { fis.close() } finally { pfd.close() }
                })
            }, adapterFactory)
        }
    }
}

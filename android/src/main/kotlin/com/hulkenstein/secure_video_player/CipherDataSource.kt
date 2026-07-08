package com.hulkenstein.secure_video_player

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * Media3 DataSource that reads an encrypted local file and decrypts each
 * chunk in place through a [CipherAdapter]. One reused 64 KB direct buffer —
 * constant memory regardless of file size.
 */
@UnstableApi
class CipherDataSource(
    private val filePath: String,
    private val adapter: CipherAdapter,
) : DataSource {

    companion object {
        private const val BUFFER_SIZE = 64 * 1024
    }

    private var file: RandomAccessFile? = null
    private var channel: FileChannel? = null
    private var ioBuffer: ByteBuffer? = null
    private var uri: Uri? = null
    private var position = 0L
    private var bytesRemaining = 0L
    private var opened = false

    @Throws(IOException::class)
    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        val f = File(filePath)
        if (!f.exists()) throw IOException("Encrypted file not found: $filePath")

        file = RandomAccessFile(f, "r")
        channel = file!!.channel
        ioBuffer = ByteBuffer.allocateDirect(BUFFER_SIZE)

        position = dataSpec.position
        if (position > 0) channel!!.position(position)

        bytesRemaining = if (dataSpec.length == C.LENGTH_UNSET.toLong()) {
            adapter.plaintextSize(f.length()) - position
        } else {
            dataSpec.length
        }
        if (bytesRemaining < 0) throw IOException("Position beyond end of file")
        opened = true
        return bytesRemaining
    }

    @Throws(IOException::class)
    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (!opened) throw IOException("DataSource not opened")
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT

        val toRead = minOf(length.toLong(), bytesRemaining, BUFFER_SIZE.toLong()).toInt()
        val buf = ioBuffer!!
        buf.clear()
        buf.limit(toRead)
        val read = channel!!.read(buf)
        if (read == -1) return C.RESULT_END_OF_INPUT

        buf.flip()
        buf.get(target, offset, read)
        adapter.transform(target, offset, read, position)

        position += read
        bytesRemaining -= read
        return read
    }

    override fun getUri(): Uri? = uri

    @Throws(IOException::class)
    override fun close() {
        opened = false
        ioBuffer = null
        try {
            channel?.close()
        } finally {
            channel = null
            try {
                file?.close()
            } finally {
                file = null
            }
        }
    }

    override fun addTransferListener(transferListener: TransferListener) {
        // Local file reads; transfer stats not reported.
    }

    class Factory(
        private val filePath: String,
        private val adapterFactory: () -> CipherAdapter,
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource =
            CipherDataSource(filePath, adapterFactory())
    }
}

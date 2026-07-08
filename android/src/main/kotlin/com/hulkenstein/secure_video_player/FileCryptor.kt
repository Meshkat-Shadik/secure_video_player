package com.hulkenstein.secure_video_player

import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Streams a file through a [CipherAdapter] on a background thread in 1 MB
 * chunks — constant memory for any file size. Encrypt and decrypt are the
 * same operation for all built-in schemes (XOR keystreams are involutions).
 */
object FileCryptor {

    private const val CHUNK = 1024 * 1024

    data class Progress(
        val operationId: String,
        val bytesProcessed: Long,
        val totalBytes: Long,
        val done: Boolean,
        val error: String? = null,
        val errorCode: String? = null,
    )

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "SecureVideoCryptor").apply { isDaemon = true }
    }
    private val cancelled = ConcurrentHashMap<String, AtomicBoolean>()

    fun start(
        inputPath: String,
        outputPath: String,
        adapter: CipherAdapter,
        onProgress: (Progress) -> Unit,
    ): String {
        val id = UUID.randomUUID().toString()
        val flag = AtomicBoolean(false)
        cancelled[id] = flag

        executor.execute {
            val output = File(outputPath)
            try {
                val input = File(inputPath)
                if (!input.exists()) {
                    onProgress(Progress(id, 0, 0, true,
                        "Input not found: $inputPath", "fileNotFound"))
                    return@execute
                }
                val total = input.length()
                var position = 0L
                val buffer = ByteArray(CHUNK)

                input.inputStream().use { ins ->
                    output.outputStream().use { outs ->
                        while (true) {
                            if (flag.get()) {
                                outs.close()
                                output.delete()
                                onProgress(Progress(id, position, total, true,
                                    "Cancelled", "unknown"))
                                return@execute
                            }
                            val read = ins.read(buffer)
                            if (read == -1) break
                            adapter.transform(buffer, 0, read, position)
                            outs.write(buffer, 0, read)
                            position += read
                            onProgress(Progress(id, position, total, false))
                        }
                    }
                }
                onProgress(Progress(id, position, total, true))
            } catch (e: Exception) {
                output.delete()
                onProgress(Progress(id, 0, 0, true,
                    e.message ?: e.javaClass.simpleName, "corruptStream"))
            } finally {
                cancelled.remove(id)
            }
        }
        return id
    }

    fun cancel(operationId: String) {
        cancelled[operationId]?.set(true)
    }
}

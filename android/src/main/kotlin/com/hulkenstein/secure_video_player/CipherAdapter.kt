package com.hulkenstein.secure_video_player

import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/**
 * Position-addressable cipher. One implementation serves both playback
 * (CipherDataSource) and file transforms (FileCryptor).
 *
 * transform() must be a pure function of (bytes, filePosition) so the player
 * can seek anywhere without streaming from byte 0.
 */
interface CipherAdapter {
    fun init(params: Map<String, Any?>)

    /** In-place transform of [length] bytes at absolute file [filePosition]. */
    fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long)

    /** Plaintext size for a given ciphertext size (identity for built-ins). */
    fun plaintextSize(cipherFileSize: Long): Long = cipherFileSize
}

/**
 * Name -> adapter factory. Apps register custom ciphers here (e.g. in
 * MainActivity.onCreate) and reference them from Dart with
 * CryptoScheme.custom(adapterName: "name").
 */
object CipherRegistry {
    private val factories = mutableMapOf<String, () -> CipherAdapter>()

    init {
        register("none") { NoneAdapter() }
        register("xorLegacy") { XorLegacyAdapter() }
        register("aesCtr") { AesCtrAdapter() }
    }

    @Synchronized
    fun register(name: String, factory: () -> CipherAdapter) {
        factories[name] = factory
    }

    @Synchronized
    fun create(name: String, params: Map<String, Any?>): CipherAdapter {
        val factory = factories[name]
            ?: throw IllegalArgumentException("No CipherAdapter registered for '$name'")
        return factory().apply { init(params) }
    }

    @Synchronized
    fun isRegistered(name: String): Boolean = factories.containsKey(name)
}

class NoneAdapter : CipherAdapter {
    override fun init(params: Map<String, Any?>) {}
    override fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long) {}
}

/**
 * Hulkenstein-compatible scheme: bytes in [skipOffset, skipOffset+corruptionSize)
 * are XORed with [key]; everything else passes through. XOR is an involution,
 * so encrypt == decrypt.
 */
class XorLegacyAdapter : CipherAdapter {
    private var skipOffset = 512L
    private var corruptionSize = 256L
    private var key: Byte = 0xAB.toByte()

    override fun init(params: Map<String, Any?>) {
        skipOffset = (params["skipOffset"] as? Number)?.toLong() ?: 512L
        corruptionSize = (params["corruptionSize"] as? Number)?.toLong() ?: 256L
        key = ((params["key"] as? Number)?.toInt() ?: 0xAB).toByte()
    }

    override fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long) {
        val rangeStart = skipOffset
        val rangeEnd = skipOffset + corruptionSize
        // Fast reject: chunk entirely outside the XOR window.
        if (filePosition >= rangeEnd || filePosition + length <= rangeStart) return
        val from = maxOf(0L, rangeStart - filePosition).toInt()
        val to = minOf(length.toLong(), rangeEnd - filePosition).toInt()
        for (i in from until to) {
            buffer[offset + i] = (buffer[offset + i].toInt() xor key.toInt()).toByte()
        }
    }
}

/**
 * AES-CTR: keystream block i = AES-ECB(key, nonce(8B) || i(8B, big-endian)).
 * Batch-generates the keystream for the whole chunk with a single doFinal so
 * JCE/AES-NI hardware acceleration applies.
 */
class AesCtrAdapter : CipherAdapter {
    private lateinit var keySpec: SecretKeySpec
    private lateinit var nonce: ByteArray

    override fun init(params: Map<String, Any?>) {
        val key = params["key"] as? ByteArray
            ?: throw IllegalArgumentException("aesCtr requires 'key' bytes")
        require(key.size == 16 || key.size == 32) { "AES key must be 16 or 32 bytes" }
        nonce = params["nonce"] as? ByteArray
            ?: throw IllegalArgumentException("aesCtr requires 'nonce' bytes")
        require(nonce.size == 8) { "nonce must be 8 bytes" }
        keySpec = SecretKeySpec(key, "AES")
    }

    override fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long) {
        if (length <= 0) return
        val firstBlock = filePosition / 16
        val skip = (filePosition % 16).toInt()
        val blockCount = ((skip + length + 15) / 16)

        // Counter plaintext: nonce || blockIndex per 16-byte block.
        val counters = ByteArray(blockCount.toInt() * 16)
        for (b in 0 until blockCount) {
            val base = (b * 16).toInt()
            System.arraycopy(nonce, 0, counters, base, 8)
            var index = firstBlock + b
            for (j in 7 downTo 0) {
                counters[base + 8 + j] = (index and 0xFF).toByte()
                index = index ushr 8
            }
        }

        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keySpec)
        val keystream = cipher.doFinal(counters)

        for (i in 0 until length) {
            buffer[offset + i] =
                (buffer[offset + i].toInt() xor keystream[skip + i].toInt()).toByte()
        }
    }
}

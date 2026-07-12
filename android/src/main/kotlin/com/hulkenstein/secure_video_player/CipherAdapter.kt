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

    /**
     * Encrypt-aware overload. [encrypt] = true when producing ciphertext
     * (FileCryptor encrypt), false when decrypting (playback / decrypt). The
     * default ignores it and delegates to [transform] — correct for the
     * built-in CTR/XOR schemes, which are involutions. Adapters that are not
     * symmetric (e.g. the Dart proxy) override this.
     */
    fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long, encrypt: Boolean) =
        transform(buffer, offset, length, filePosition)

    /** Plaintext size for a given ciphertext size (identity for built-ins). */
    fun plaintextSize(cipherFileSize: Long): Long = cipherFileSize
}

/**
 * Name -> adapter factory for the built-in schemes (none, xorLegacy, aesCtr).
 * Resolved by wire scheme type from the `CryptoScheme` sent by Dart.
 */
object CipherRegistry {
    private val factories = mutableMapOf<String, () -> CipherAdapter>()

    init {
        register(SvpProtocol.SCHEME_NONE) { NoneAdapter() }
        register(SvpProtocol.SCHEME_XOR_LEGACY) { XorLegacyAdapter() }
        register(SvpProtocol.SCHEME_AES_CTR) { AesCtrAdapter() }
    }

    @Synchronized
    fun register(name: String, factory: () -> CipherAdapter) {
        factories[name] = factory
    }

    /** Removes [name] only if [factory] is still the registered one (identity
     *  match), so a later engine's registration is never clobbered. */
    @Synchronized
    fun unregister(name: String, factory: () -> CipherAdapter) {
        if (factories[name] === factory) factories.remove(name)
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
    private lateinit var nonce: ByteArray
    // Cipher created and keyed once per adapter (key is immutable for its
    // lifetime). Reused across transform() calls to skip the JCE provider
    // lookup + AES key-schedule expansion on every chunk. ECB doFinal carries
    // no state between calls, so no re-init is needed. Safe without locks: each
    // adapter instance is owned by a single reader (ExoPlayer DataSource,
    // FileCryptor's single-thread executor, or a MediaInfoProbe source guarded
    // by synchronized(file)) and transform() is never called concurrently.
    private lateinit var cipher: Cipher

    override fun init(params: Map<String, Any?>) {
        val key = params["key"] as? ByteArray
            ?: throw IllegalArgumentException("aesCtr requires 'key' bytes")
        require(key.size == 16 || key.size == 32) { "AES key must be 16 or 32 bytes" }
        nonce = params["nonce"] as? ByteArray
            ?: throw IllegalArgumentException("aesCtr requires 'nonce' bytes")
        require(nonce.size == 8) { "nonce must be 8 bytes" }
        cipher = Cipher.getInstance("AES/ECB/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
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

        val keystream = cipher.doFinal(counters)

        for (i in 0 until length) {
            buffer[offset + i] =
                (buffer[offset + i].toInt() xor keystream[skip + i].toInt()).toByte()
        }
    }
}

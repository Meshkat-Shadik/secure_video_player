package com.hulkenstein.secure_video_player

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertContentEquals as assertBytes
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CipherAdapterTest {

    private val key = ByteArray(16) { (it * 7 + 13).toByte() }
    private val nonce = ByteArray(8) { (it * 31 + 5).toByte() }
    private val plaintext = Random(42).nextBytes(300_000)

    private fun aes() = AesCtrAdapter().apply {
        init(mapOf("key" to key, "nonce" to nonce))
    }

    private fun xor() = XorLegacyAdapter().apply { init(emptyMap()) }

    @Test
    fun `aes-ctr round trip restores plaintext`() {
        val buffer = plaintext.copyOf()
        aes().transform(buffer, 0, buffer.size, 0)
        assertFalse(buffer.contentEquals(plaintext), "ciphertext must differ")
        aes().transform(buffer, 0, buffer.size, 0)
        assertBytes(plaintext, buffer)
    }

    @Test
    fun `aes-ctr transform at offset equals slice of full transform (seek correctness)`() {
        val full = plaintext.copyOf()
        aes().transform(full, 0, full.size, 0)

        // Decrypt-at-position with offsets that cross and split AES blocks.
        for (position in listOf(1L, 15L, 16L, 17L, 4096L, 65_537L, 131_072L)) {
            val length = 50_000
            val slice = plaintext.copyOfRange(position.toInt(), position.toInt() + length)
            aes().transform(slice, 0, length, position)
            assertBytes(
                full.copyOfRange(position.toInt(), position.toInt() + length),
                slice,
                "mismatch at position $position",
            )
        }
    }

    @Test
    fun `aes-ctr rejects bad key sizes`() {
        assertFailsWith<IllegalArgumentException> {
            AesCtrAdapter().init(mapOf("key" to ByteArray(10), "nonce" to nonce))
        }
        assertFailsWith<IllegalArgumentException> {
            AesCtrAdapter().init(mapOf("key" to key, "nonce" to ByteArray(4)))
        }
    }

    @Test
    fun `xor legacy is hulkenstein compatible`() {
        val buffer = plaintext.copyOf()
        xor().transform(buffer, 0, buffer.size, 0)
        // Bytes [0,512) untouched, [512,768) XOR 0xAB, rest untouched.
        for (i in 0 until 512) assertTrue(buffer[i] == plaintext[i])
        for (i in 512 until 768) {
            assertTrue(buffer[i] == (plaintext[i].toInt() xor 0xAB).toByte())
        }
        for (i in 768 until buffer.size) assertTrue(buffer[i] == plaintext[i])
        // Involution.
        xor().transform(buffer, 0, buffer.size, 0)
        assertBytes(plaintext, buffer)
    }

    @Test
    fun `xor legacy chunked reads match whole-file transform`() {
        val whole = plaintext.copyOf()
        xor().transform(whole, 0, whole.size, 0)

        val chunked = plaintext.copyOf()
        val adapter = xor()
        var position = 0
        val chunkSizes = listOf(100, 412, 256, 1024, 64 * 1024)
        var chunkIndex = 0
        while (position < chunked.size) {
            val size = minOf(chunkSizes[chunkIndex % chunkSizes.size], chunked.size - position)
            adapter.transform(chunked, position, size, position.toLong())
            position += size
            chunkIndex++
        }
        assertContentEquals(whole, chunked)
    }

    @Test
    fun `none adapter passes through`() {
        val buffer = plaintext.copyOf()
        NoneAdapter().transform(buffer, 0, buffer.size, 12345L)
        assertBytes(plaintext, buffer)
    }

    @Test
    fun `registry resolves built-ins and rejects unknown`() {
        assertTrue(CipherRegistry.isRegistered("aesCtr"))
        assertTrue(CipherRegistry.isRegistered("xorLegacy"))
        assertTrue(CipherRegistry.isRegistered("none"))
        assertFailsWith<IllegalArgumentException> {
            CipherRegistry.create("nope", emptyMap())
        }
    }
}

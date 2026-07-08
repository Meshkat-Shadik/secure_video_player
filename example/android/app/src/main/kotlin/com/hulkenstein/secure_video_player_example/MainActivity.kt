package com.hulkenstein.secure_video_player_example

import com.hulkenstein.secure_video_player.CipherAdapter
import com.hulkenstein.secure_video_player.CipherRegistry
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Custom cipher demo: register once, reference from Dart with
        // CryptoScheme.custom(adapterName: 'repeatingXor').
        CipherRegistry.register("repeatingXor") { RepeatingXorAdapter() }
    }
}

/**
 * Example custom cipher: XOR every byte with a repeating multi-byte key.
 * Position-addressable (keystream byte = key[position % key.size]) so
 * seeking works. XOR is an involution: encrypt == decrypt.
 */
class RepeatingXorAdapter : CipherAdapter {
    private var key = byteArrayOf(0x5A)

    override fun init(params: Map<String, Any?>) {
        val list = params["key"] as? List<*>
            ?: throw IllegalArgumentException("repeatingXor requires 'key' list")
        key = ByteArray(list.size) { (list[it] as Number).toByte() }
    }

    override fun transform(buffer: ByteArray, offset: Int, length: Int, filePosition: Long) {
        for (i in 0 until length) {
            val k = key[((filePosition + i) % key.size).toInt()]
            buffer[offset + i] = (buffer[offset + i].toInt() xor k.toInt()).toByte()
        }
    }
}

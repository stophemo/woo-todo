package com.wootodo.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairingCryptoInstrumentedTest {
    @Test
    fun `当前Android设备可以生成X25519密钥并完成双方协商`() {
        val initiator = PairingKeyPair.generate()
        try {
            val claimant = PairingKeyPair.generate()
            try {
                val pairingSecret = ByteArray(32) { (it + 1).toByte() }
                val first = initiator.sessionKey(
                    claimant.publicKey,
                    "pairing-provider-test",
                    pairingSecret,
                )
                val second = claimant.sessionKey(
                    initiator.publicKey,
                    "pairing-provider-test",
                    pairingSecret,
                )

                try {
                    assertEquals(32, initiator.publicKey.size)
                    assertEquals(32, claimant.publicKey.size)
                    assertArrayEquals(first, second)
                } finally {
                    pairingSecret.fill(0)
                    first.fill(0)
                    second.fill(0)
                }
            } finally {
                claimant.destroy()
            }
        } finally {
            initiator.destroy()
        }
    }
}

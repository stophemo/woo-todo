package com.wootodo.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingSessionGenerationTest {
    @Test
    fun `新扫码会使旧恢复流程的结果失效`() {
        val generation = PairingSessionGeneration()
        val recovery = generation.current()

        generation.advance()

        assertFalse(generation.isCurrent(recovery))
        assertTrue(generation.isCurrent(generation.current()))
    }

    @Test
    fun `后一次扫码会拒绝先一次晚到的预检查结果`() {
        val generation = PairingSessionGeneration()
        val firstScan = generation.advance()
        val secondScan = generation.advance()

        assertFalse(generation.isCurrent(firstScan))
        assertTrue(generation.isCurrent(secondScan))
    }
}

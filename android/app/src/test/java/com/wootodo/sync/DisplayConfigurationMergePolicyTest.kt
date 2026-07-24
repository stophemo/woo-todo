package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayConfigurationMergePolicyTest {
    @Test
    fun `显示配置使用Lamport和设备ID确定性合并`() {
        val current = configuration("当前")
        val incoming = configuration("传入")

        val older = DisplayConfigurationMergePolicy.resolve(
            currentConfiguration = current,
            currentVersion = EntityVersion(8, "device-z"),
            incomingConfiguration = incoming,
            incomingVersion = EntityVersion(7, "device-a"),
        )
        assertEquals(current, older.resolvedConfiguration)
        assertEquals(EntityVersion(8, "device-z"), older.resolvedVersion)

        val newer = DisplayConfigurationMergePolicy.resolve(
            currentConfiguration = current,
            currentVersion = EntityVersion(8, "device-z"),
            incomingConfiguration = incoming,
            incomingVersion = EntityVersion(9, "device-a"),
        )
        assertEquals(incoming, newer.resolvedConfiguration)
        assertEquals(EntityVersion(9, "device-a"), newer.resolvedVersion)

        val tieBrokenByDevice = DisplayConfigurationMergePolicy.resolve(
            currentConfiguration = current,
            currentVersion = EntityVersion(9, "device-a"),
            incomingConfiguration = incoming,
            incomingVersion = EntityVersion(9, "device-z"),
        )
        assertEquals(incoming, tieBrokenByDevice.resolvedConfiguration)
        assertEquals(EntityVersion(9, "device-z"), tieBrokenByDevice.resolvedVersion)
    }

    private fun configuration(label: String) = DisplayConfigurationPayload(
        headerTemplate = "$label {weekday}",
        subtitleTemplate = "$label {elapsedDays}",
        startDate = "2026-01-01",
        deadlineDate = "2026-12-31",
    )
}

package com.wootodo.sync

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SyncJsonCodecTest {
    @Test
    fun `同步body不携带vault和device且字段严格`() {
        val request = SyncRequest(
            cursor = 41,
            ack = 41,
            pullLimit = 100,
            push = listOf(
                SyncPushOperation(
                    opId = "op_01JZ7X0B8E6V5P4N3M2K",
                    entityId = "task_01JZ7WZX2WQ9A8B7C6D5",
                    kind = SyncOperationKind.UPSERT,
                    lamport = 12,
                    nonce = "AAECAwQFBgcICQoL",
                    ciphertext = "VGhpcy1pcy1hLXRlc3QtY2lwaGVydGV4dA",
                ),
            ),
        )

        val objectValue = JSONObject(SyncJsonCodec.encode(request))

        assertEquals(setOf("cursor", "ack", "pullLimit", "push"), objectValue.keys().asSequence().toSet())
        assertFalse(objectValue.has("vaultId"))
        assertFalse(objectValue.has("deviceId"))
    }

    @Test
    fun `成功响应拒绝未知字段`() {
        val source = """
            {"ok":true,"data":{"push":{"received":0,"inserted":0,"duplicates":0},
            "pull":[],"cursor":0,"hasMore":false,"serverTime":1,"extra":true},
            "requestId":"req-1"}
        """.trimIndent()

        assertThrows(ProtocolJsonException::class.java) {
            SyncJsonCodec.decodeSyncData(source)
        }
    }

    @Test
    fun `任务payload覆盖实例快照与墓碑`() {
        val taskSource = """
            {
              "protocolVersion":1,"entityType":"task",
              "id":"550e8400-e29b-41d4-a716-446655440000",
              "seriesId":"550e8400-e29b-41d4-a716-446655440000",
              "title":"整理明日工作","timeType":"day","periodStart":"2026-07-16",
              "timezone":"Asia/Shanghai","questLine":"main","state":"pending",
              "recurrence":"repeat","sortOrder":0,"createdAt":1,"updatedAt":1,"settledAt":null
            }
        """.trimIndent()
        val payload = SyncJsonCodec.decodeTaskPayload(taskSource) as TaskInstancePayload

        assertEquals("550e8400-e29b-41d4-a716-446655440000", payload.seriesId)
        assertEquals("2026-07-16", payload.periodStart)
        assertEquals(WireRecurrence.REPEAT, payload.recurrence)
        assertTrue(SyncJsonCodec.encodeTaskPayload(payload).contains("\"entityType\":\"task\""))

        val tombstone = SyncJsonCodec.decodeTaskPayload(
            """{"protocolVersion":1,"entityType":"tombstone","id":"task_12345678","deletedAt":2}""",
        )
        assertTrue(tombstone is TombstonePayload)
    }

    @Test
    fun `显示配置payload严格编解码`() {
        val payload = DisplayConfigurationPayload(
            headerTemplate = "{dateLong} {weekdayEn}",
            subtitleTemplate = "已走过 {elapsedMonthsDays}，距截止 {deadlineMonthsDays}",
            startDate = "2020-01-01",
            deadlineDate = "2026-12-31",
        )

        val encoded = SyncJsonCodec.encodeTaskPayload(payload)
        val objectValue = JSONObject(encoded)

        assertEquals(
            setOf(
                "protocolVersion", "entityType", "id", "headerTemplate",
                "subtitleTemplate", "startDate", "deadlineDate",
            ),
            objectValue.keys().asSequence().toSet(),
        )
        assertEquals(payload, SyncJsonCodec.decodeTaskPayload(encoded))
    }

    @Test
    fun `显示配置payload拒绝非法值`() {
        val valid = JSONObject(
            SyncJsonCodec.encodeTaskPayload(
                DisplayConfigurationPayload(
                    headerTemplate = "{dateLong} {weekdayEn}",
                    subtitleTemplate = "已走过 {elapsedMonthsDays}",
                    startDate = "2020-01-01",
                    deadlineDate = "2026-12-31",
                ),
            ),
        )
        val invalidPayloads = listOf(
            JSONObject(valid.toString()).put("id", "display.today.other"),
            JSONObject(valid.toString()).put("headerTemplate", "标".repeat(81)),
            JSONObject(valid.toString()).put("subtitleTemplate", "题".repeat(161)),
            JSONObject(valid.toString()).put("subtitleTemplate", "第一行\n第二行"),
            JSONObject(valid.toString()).put("headerTemplate", "第一行\u2028第二行"),
            JSONObject(valid.toString()).put("deadlineDate", "2026-02-30"),
            JSONObject(valid.toString()).apply { remove("startDate") },
            JSONObject(valid.toString()).put("unexpected", true),
        )

        invalidPayloads.forEach { invalid ->
            assertThrows(Exception::class.java) {
                SyncJsonCodec.decodeTaskPayload(invalid.toString())
            }
        }
    }

    @Test
    fun `共享Wire v1边界正反例在Kotlin中严格一致`() {
        val source = requireNotNull(
            javaClass.classLoader?.getResourceAsStream("task-validation-cases.json"),
        ) { "缺少共享 Wire v1 校验 fixture" }
            .bufferedReader()
            .use { it.readText() }
        val root = JSONObject(source)
        val valid = root.getJSONArray("valid")
        val invalid = root.getJSONArray("invalid")
        assertTrue(valid.length() >= 4)
        assertTrue(invalid.length() >= 10)

        repeat(valid.length()) { index ->
            val testCase = valid.getJSONObject(index)
            val name = testCase.getString("name")
            try {
                SyncJsonCodec.decodeTaskPayload(testCase.getJSONObject("payload").toString())
            } catch (error: Exception) {
                fail("有效 fixture 被拒绝：$name，${error.message}")
            }
        }

        repeat(invalid.length()) { index ->
            val testCase = invalid.getJSONObject(index)
            val name = testCase.getString("name")
            val accepted = runCatching {
                SyncJsonCodec.decodeTaskPayload(testCase.getJSONObject("payload").toString())
            }.isSuccess
            if (accepted) fail("无效 fixture 未被拒绝：$name")
        }
    }
}

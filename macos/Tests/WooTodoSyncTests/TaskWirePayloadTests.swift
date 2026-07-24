import Foundation
import Testing
@testable import WooTodoSync

@Suite("任务密文正文协议")
struct TaskWirePayloadTests {
    @Test("共享 payload fixtures 可严格解码并往返")
    func sharedFixturesRoundTrip() throws {
        let data = try Data(contentsOf: fixtureURL())
        let payloads = try JSONDecoder().decode([WireTaskEntity].self, from: data)
        #expect(payloads.count == 4)

        guard case .task(let first) = payloads[0] else {
            Issue.record("第一条应为任务正文")
            return
        }
        #expect(first.seriesId == "550e8400-e29b-41d4-a716-446655440000")
        #expect(first.periodStart == "2026-07-16")
        #expect(first.recurrence == .repeatRule)
        #expect(first.reminderTime == "23:10")
        #expect(first.settledAt == nil)

        guard case .tombstone(let tombstone) = payloads[2] else {
            Issue.record("第三条应为 tombstone")
            return
        }
        #expect(tombstone.deletedAt == 1_784_251_800_000)

        guard case .displayConfiguration(let displayConfiguration) = payloads[3] else {
            Issue.record("第四条应为显示配置正文")
            return
        }
        #expect(displayConfiguration.id == WireDisplayConfigurationPayload.fixedID)
        #expect(displayConfiguration.headerTemplate == "{dateLong} {weekdayEn}")
        #expect(displayConfiguration.subtitleTemplate.contains("{deadlineMonthsDays}"))
        #expect(displayConfiguration.startDate == "2020-01-01")
        #expect(displayConfiguration.deadlineDate == "2026-12-31")

        for payload in payloads {
            #expect(try TaskPayloadCodec.decode(TaskPayloadCodec.encode(payload)) == payload)
        }
    }

    @Test("payload 可使用 vault key 与同步 AAD 加密往返")
    func encryptedRoundTrip() throws {
        let payloads = try JSONDecoder().decode(
            [WireTaskEntity].self,
            from: Data(contentsOf: fixtureURL())
        )
        let payload = try #require(payloads.first)
        let vaultKey = Data(repeating: 11, count: AES256GCM.keyByteCount)
        let metadata = SyncAADMetadata(
            vaultId: "vault-test",
            operationId: "op-test",
            entityId: "task-test",
            kind: .upsert,
            lamport: 7,
            deviceId: "device-test"
        )
        let envelope = try TaskPayloadCodec.seal(
            payload,
            vaultKey: vaultKey,
            metadata: metadata,
            nonce: Data(repeating: 12, count: AES256GCM.nonceByteCount)
        )
        #expect(
            try TaskPayloadCodec.open(
                envelope,
                vaultKey: vaultKey,
                metadata: metadata
            ) == payload
        )
    }

    @Test("所有正文类型拒绝未知字段")
    func rejectsUnknownFields() throws {
        let payloads = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtureURL())
        ) as? [[String: Any]]
        var task = try #require(payloads?.first)
        task["unexpected"] = true
        #expect(throws: (any Error).self) {
            try TaskPayloadCodec.decode(JSONSerialization.data(withJSONObject: task))
        }

        var tombstone = try #require(payloads?[2])
        tombstone["unexpected"] = true
        #expect(throws: (any Error).self) {
            try TaskPayloadCodec.decode(JSONSerialization.data(withJSONObject: tombstone))
        }

        var displayConfiguration = try #require(payloads?[3])
        displayConfiguration["unexpected"] = true
        #expect(throws: (any Error).self) {
            try TaskPayloadCodec.decode(
                JSONSerialization.data(withJSONObject: displayConfiguration)
            )
        }
    }

    @Test("显示配置可编解码并拒绝非法值")
    func displayConfigurationValidation() throws {
        let payload = try WireDisplayConfigurationPayload(
            headerTemplate: "{dateLong} {weekdayEn}",
            subtitleTemplate: "已走过 {elapsedMonthsDays}",
            startDate: "2020-01-01",
            deadlineDate: "2026-12-31"
        )
        let entity = WireTaskEntity.displayConfiguration(payload)
        #expect(try TaskPayloadCodec.decode(TaskPayloadCodec.encode(entity)) == entity)

        let fixtures = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtureURL())
        ) as? [[String: Any]]
        let valid = try #require(fixtures?[3])

        var wrongID = valid
        wrongID["id"] = "display.today.other"
        var longHeader = valid
        longHeader["headerTemplate"] = String(repeating: "标", count: 81)
        var longSubtitle = valid
        longSubtitle["subtitleTemplate"] = String(repeating: "题", count: 161)
        var multilineTemplate = valid
        multilineTemplate["subtitleTemplate"] = "第一行\n第二行"
        var unicodeLineSeparator = valid
        unicodeLineSeparator["headerTemplate"] = "第一行\u{2028}第二行"
        var invalidDate = valid
        invalidDate["deadlineDate"] = "2026-02-30"
        var missingField = valid
        missingField.removeValue(forKey: "startDate")

        for invalid in [
            wrongID, longHeader, longSubtitle, multilineTemplate, unicodeLineSeparator,
            invalidDate, missingField,
        ] {
            #expect(throws: (any Error).self) {
                try TaskPayloadCodec.decode(JSONSerialization.data(withJSONObject: invalid))
            }
        }
    }

    @Test("共享 Wire v1 边界正反例在 Swift 中严格一致")
    func sharedValidationCases() throws {
        let data = try Data(contentsOf: fixtureURL("task-validation-cases.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valid = root["valid"] as? [[String: Any]],
              let invalid = root["invalid"] as? [[String: Any]] else {
            Issue.record("Wire v1 校验 fixture 结构无效")
            return
        }
        #expect(valid.count >= 4)
        #expect(invalid.count >= 10)

        for testCase in valid {
            guard let name = testCase["name"] as? String,
                  let payload = testCase["payload"] else {
                Issue.record("有效 fixture 缺少名称或 payload")
                continue
            }
            do {
                let payloadData = try JSONSerialization.data(withJSONObject: payload)
                _ = try JSONDecoder().decode(WireTaskEntity.self, from: payloadData)
            } catch {
                Issue.record("有效 fixture 被拒绝：\(name)，\(error.localizedDescription)")
            }
        }

        for testCase in invalid {
            guard let name = testCase["name"] as? String,
                  let payload = testCase["payload"] else {
                Issue.record("无效 fixture 缺少名称或 payload")
                continue
            }
            do {
                let payloadData = try JSONSerialization.data(withJSONObject: payload)
                _ = try JSONDecoder().decode(WireTaskEntity.self, from: payloadData)
                Issue.record("无效 fixture 未被拒绝：\(name)")
            } catch {
                // 预期拒绝。
            }
        }
    }

    private func fixtureURL(_ name: String = "task-payloads.json") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(name)
    }
}

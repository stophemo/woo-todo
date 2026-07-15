import Foundation
import Testing
@testable import WooTodoCore

@Suite("跨端重复实例 ID")
struct OccurrenceIDGeneratorTests {
    @Test("共享 golden 第一向量与其他端一致")
    func sharedGoldenVector() {
        let seriesID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let periodStart = ISO8601DateFormatter().date(from: "2026-07-16T00:00:00+08:00")!

        let id = OccurrenceIDGenerator.makeID(
            seriesID: seriesID,
            scope: .daily,
            periodStart: periodStart
        )

        #expect(id.uuidString.lowercased() == "bd19b6b6-7f10-55af-bf1e-323457e79404")
    }

    @Test("固定协议向量生成固定 UUID")
    func fixedVector() {
        let seriesID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let periodStart = ISO8601DateFormatter().date(from: "2026-07-15T16:00:00Z")!

        let canonical = OccurrenceIDGenerator.canonicalString(
            seriesID: seriesID,
            scope: .daily,
            periodStart: periodStart
        )
        let id = OccurrenceIDGenerator.makeID(
            seriesID: seriesID,
            scope: .daily,
            periodStart: periodStart
        )

        #expect(canonical == "woo-todo-occurrence-v1|01234567-89ab-cdef-0123-456789abcdef|day|2026-07-16")
        #expect(id.uuidString.lowercased() == "d43835d1-bf2b-50d3-ab39-0490d765b442")
    }

    @Test("相同输入始终得到相同实例 ID")
    func deterministicForSameInput() {
        let seriesID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let start = ISO8601DateFormatter().date(from: "2026-08-03T00:00:00+08:00")!

        let first = OccurrenceIDGenerator.makeID(
            seriesID: seriesID,
            scope: .weekly,
            periodStart: start
        )
        let second = OccurrenceIDGenerator.makeID(
            seriesID: seriesID,
            scope: .weekly,
            periodStart: start
        )

        #expect(first == second)
    }
}

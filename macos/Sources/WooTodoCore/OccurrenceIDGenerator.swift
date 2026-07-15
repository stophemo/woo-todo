import CryptoKit
import Foundation

/// 根据跨端协议生成稳定的重复实例 ID，避免离线设备各自产生随机 UUID。
public enum OccurrenceIDGenerator {
    public static let defaultTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    public static func makeID(
        seriesID: UUID,
        scope: TimeScope,
        periodStart: Date,
        timeZone: TimeZone = defaultTimeZone
    ) -> UUID {
        let canonical = canonicalString(
            seriesID: seriesID,
            scope: scope,
            periodStart: periodStart,
            timeZone: timeZone
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }

    public static func canonicalString(
        seriesID: UUID,
        scope: TimeScope,
        periodStart: Date,
        timeZone: TimeZone = defaultTimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: periodStart)
        let localDate = String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year!,
            components.month!,
            components.day!
        )
        return [
            "woo-todo-occurrence-v1",
            seriesID.uuidString.lowercased(),
            scope.rawValue,
            localDate
        ].joined(separator: "|")
    }
}

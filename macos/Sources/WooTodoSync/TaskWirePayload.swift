import Foundation

public enum WireTaskTimeType: String, Codable, Sendable {
    case day
    case week
    case month
    case someday
}

public enum WireQuestLine: String, Codable, Sendable {
    case main
    case side
    case extra
}

public enum WireTaskState: String, Codable, Sendable {
    case pending
    case completed
    case pass
}

public enum WireRecurrence: String, Codable, Sendable {
    case once
    case repeatRule = "repeat"
}

public enum TaskPayloadValidationError: Error, Equatable, LocalizedError {
    case unsupportedProtocolVersion(Int)
    case invalidEntityType(String)
    case invalidField(String)
    case invalidStateCombination

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let value): "不支持任务正文协议版本：\(value)"
        case .invalidEntityType(let value): "不支持任务正文实体类型：\(value)"
        case .invalidField(let field): "任务正文的 \(field) 字段无效"
        case .invalidStateCombination: "任务正文的时间类型、状态或结算字段组合无效"
        }
    }
}

public struct WireTaskPayload: Codable, Equatable, Sendable {
    public static let fixedTimeZone = "Asia/Shanghai"
    public static let maximumSortOrder = Int64(Int32.max)
    public static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case entityType
        case id
        case seriesId
        case title
        case timeType
        case periodStart
        case timezone
        case questLine
        case state
        case recurrence
        case sortOrder
        case createdAt
        case updatedAt
        case reminderTime
        case settledAt
    }

    public let protocolVersion: Int
    public let entityType: String
    public let id: String
    public let seriesId: String
    public let title: String
    public let timeType: WireTaskTimeType
    public let periodStart: String?
    public let timezone: String
    public let questLine: WireQuestLine
    public let state: WireTaskState
    public let recurrence: WireRecurrence
    public let sortOrder: Int64
    public let createdAt: Int64
    public let updatedAt: Int64
    public let reminderTime: String?
    public let settledAt: Int64?

    public init(
        id: String,
        seriesId: String,
        title: String,
        timeType: WireTaskTimeType,
        periodStart: String?,
        timezone: String,
        questLine: WireQuestLine,
        state: WireTaskState,
        recurrence: WireRecurrence,
        sortOrder: Int64,
        createdAt: Int64,
        updatedAt: Int64,
        reminderTime: String? = nil,
        settledAt: Int64?
    ) throws {
        self.protocolVersion = 1
        self.entityType = "task"
        self.id = id
        self.seriesId = seriesId
        self.title = title
        self.timeType = timeType
        self.periodStart = periodStart
        self.timezone = timezone
        self.questLine = questLine
        self.state = state
        self.recurrence = recurrence
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reminderTime = reminderTime
        self.settledAt = settledAt
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try requireTaskPayloadKeys(
            decoder,
            required: [
                "protocolVersion", "entityType", "id", "seriesId", "title",
                "timeType", "periodStart", "timezone", "questLine", "state",
                "recurrence", "sortOrder", "createdAt", "updatedAt", "settledAt",
            ],
            optional: ["reminderTime"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.periodStart), container.contains(.settledAt) else {
            let missingKey: CodingKeys = container.contains(.periodStart) ? .settledAt : .periodStart
            throw DecodingError.keyNotFound(
                missingKey,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "任务正文必须显式包含 periodStart 与 settledAt"
                )
            )
        }
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        self.entityType = try container.decode(String.self, forKey: .entityType)
        self.id = try container.decode(String.self, forKey: .id)
        self.seriesId = try container.decode(String.self, forKey: .seriesId)
        self.title = try container.decode(String.self, forKey: .title)
        self.timeType = try container.decode(WireTaskTimeType.self, forKey: .timeType)
        self.periodStart = try container.decodeIfPresent(String.self, forKey: .periodStart)
        self.timezone = try container.decode(String.self, forKey: .timezone)
        self.questLine = try container.decode(WireQuestLine.self, forKey: .questLine)
        self.state = try container.decode(WireTaskState.self, forKey: .state)
        self.recurrence = try container.decode(WireRecurrence.self, forKey: .recurrence)
        self.sortOrder = try container.decode(Int64.self, forKey: .sortOrder)
        self.createdAt = try container.decode(Int64.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        self.reminderTime = try container.decodeIfPresent(String.self, forKey: .reminderTime)
        self.settledAt = try container.decodeIfPresent(Int64.self, forKey: .settledAt)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(entityType, forKey: .entityType)
        try container.encode(id, forKey: .id)
        try container.encode(seriesId, forKey: .seriesId)
        try container.encode(title, forKey: .title)
        try container.encode(timeType, forKey: .timeType)
        if let periodStart {
            try container.encode(periodStart, forKey: .periodStart)
        } else {
            try container.encodeNil(forKey: .periodStart)
        }
        try container.encode(timezone, forKey: .timezone)
        try container.encode(questLine, forKey: .questLine)
        try container.encode(state, forKey: .state)
        try container.encode(recurrence, forKey: .recurrence)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        if let reminderTime {
            try container.encode(reminderTime, forKey: .reminderTime)
        }
        if let settledAt {
            try container.encode(settledAt, forKey: .settledAt)
        } else {
            try container.encodeNil(forKey: .settledAt)
        }
    }

    public func validate() throws {
        guard protocolVersion == 1 else {
            throw TaskPayloadValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard entityType == "task" else {
            throw TaskPayloadValidationError.invalidEntityType(entityType)
        }
        guard isValidTaskIdentifier(id) else {
            throw TaskPayloadValidationError.invalidField("id")
        }
        guard isValidTaskIdentifier(seriesId) else {
            throw TaskPayloadValidationError.invalidField("seriesId")
        }
        guard (1...120).contains(title.unicodeScalars.count) else {
            throw TaskPayloadValidationError.invalidField("title")
        }
        guard timezone == Self.fixedTimeZone,
              (0...Self.maximumSortOrder).contains(sortOrder),
              (0...Self.maximumSafeInteger).contains(createdAt),
              (0...Self.maximumSafeInteger).contains(updatedAt),
              reminderTime.map(Self.isValidReminderTime) ?? true,
              settledAt.map({ (0...Self.maximumSafeInteger).contains($0) }) ?? true else {
            throw TaskPayloadValidationError.invalidField("range")
        }

        if timeType == .someday {
            guard periodStart == nil, recurrence == .once, reminderTime == nil else {
                throw TaskPayloadValidationError.invalidStateCombination
            }
        } else {
            guard let periodStart,
                  Self.isValidPeriodStart(periodStart, for: timeType) else {
                throw TaskPayloadValidationError.invalidField("periodStart")
            }
        }
        if state == .pending {
            guard settledAt == nil else {
                throw TaskPayloadValidationError.invalidStateCombination
            }
        } else if settledAt == nil {
            throw TaskPayloadValidationError.invalidStateCombination
        }
    }

    private static func isValidPeriodStart(
        _ value: String,
        for timeType: WireTaskTimeType
    ) -> Bool {
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
            options: .regularExpression
        ) != nil else { return false }
        let components = value.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              (1...9_999).contains(year) else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: fixedTimeZone)!
        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.timeZone = calendar.timeZone
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        guard let date = calendar.date(from: dateComponents) else { return false }
        let normalized = calendar.dateComponents(
            [.year, .month, .day, .weekday],
            from: date
        )
        guard normalized.year == year,
              normalized.month == month,
              normalized.day == day else { return false }

        switch timeType {
        case .day:
            return true
        case .week:
            return normalized.weekday == 2
        case .month:
            return day == 1
        case .someday:
            return false
        }
    }

    private static func isValidReminderTime(_ value: String) -> Bool {
        value.range(
            of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#,
            options: .regularExpression
        ) != nil
    }
}

public struct WireTombstonePayload: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let entityType: String
    public let id: String
    public let deletedAt: Int64

    public init(id: String, deletedAt: Int64) throws {
        self.protocolVersion = 1
        self.entityType = "tombstone"
        self.id = id
        self.deletedAt = deletedAt
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try requireExactTaskPayloadKeys(
            decoder,
            expected: ["protocolVersion", "entityType", "id", "deletedAt"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        self.entityType = try container.decode(String.self, forKey: .entityType)
        self.id = try container.decode(String.self, forKey: .id)
        self.deletedAt = try container.decode(Int64.self, forKey: .deletedAt)
        try validate()
    }

    public func validate() throws {
        guard protocolVersion == 1 else {
            throw TaskPayloadValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard entityType == "tombstone" else {
            throw TaskPayloadValidationError.invalidEntityType(entityType)
        }
        guard isValidTaskIdentifier(id),
              (0...WireTaskPayload.maximumSafeInteger).contains(deletedAt) else {
            throw TaskPayloadValidationError.invalidField("tombstone")
        }
    }
}

private func isValidTaskIdentifier(_ value: String) -> Bool {
    (8...128).contains(value.unicodeScalars.count)
        && value.range(
            of: #"^[A-Za-z0-9._:-]+$"#,
            options: .regularExpression
        ) != nil
}

private struct TaskPayloadAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func requireExactTaskPayloadKeys(
    _ decoder: Decoder,
    expected: Set<String>
) throws {
    let container = try decoder.container(keyedBy: TaskPayloadAnyCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "任务正文 JSON 字段不匹配"
            )
        )
    }
}

private func requireTaskPayloadKeys(
    _ decoder: Decoder,
    required: Set<String>,
    optional: Set<String>
) throws {
    let container = try decoder.container(keyedBy: TaskPayloadAnyCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard required.isSubset(of: actual), actual.subtracting(required).isSubset(of: optional) else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "任务正文 JSON 字段不匹配"
            )
        )
    }
}

public enum WireTaskEntity: Codable, Equatable, Sendable {
    case task(WireTaskPayload)
    case tombstone(WireTombstonePayload)

    private enum CodingKeys: String, CodingKey {
        case entityType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .entityType) {
        case "task": self = .task(try WireTaskPayload(from: decoder))
        case "tombstone": self = .tombstone(try WireTombstonePayload(from: decoder))
        case let type: throw TaskPayloadValidationError.invalidEntityType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .task(let payload): try payload.encode(to: encoder)
        case .tombstone(let payload): try payload.encode(to: encoder)
        }
    }
}

public enum TaskPayloadCodec {
    public static func encode(_ payload: WireTaskEntity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data) throws -> WireTaskEntity {
        try JSONDecoder().decode(WireTaskEntity.self, from: data)
    }

    public static func seal(
        _ payload: WireTaskEntity,
        vaultKey: Data,
        metadata: SyncAADMetadata,
        nonce: Data? = nil
    ) throws -> EncryptedEnvelope {
        try AES256GCM.seal(
            encode(payload),
            key: vaultKey,
            nonce: nonce,
            authenticating: SyncAAD.data(metadata)
        )
    }

    public static func open(
        _ envelope: EncryptedEnvelope,
        vaultKey: Data,
        metadata: SyncAADMetadata
    ) throws -> WireTaskEntity {
        let data = try AES256GCM.open(
            envelope,
            key: vaultKey,
            authenticating: SyncAAD.data(metadata)
        )
        return try decode(data)
    }
}

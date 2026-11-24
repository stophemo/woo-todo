import Foundation

/// WebDAV 设备心跳密文内的明文。仅设备名、平台、最近同步时间与应用版本，
/// WebDAV 供应商只能看到外层信封。
public struct WebDavDeviceHeartbeat: Codable, Equatable, Sendable {
    public let name: String
    public let platform: DevicePlatform
    /// 毫秒时间戳。
    public let lastSeenAt: Int64
    public let appVersion: String

    public init(
        name: String,
        platform: DevicePlatform,
        lastSeenAt: Int64,
        appVersion: String
    ) throws {
        self.name = name
        self.platform = platform
        self.lastSeenAt = lastSeenAt
        self.appVersion = appVersion
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WebDavDeviceCodingKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        let expected = Set(["name", "platform", "lastSeenAt", "appVersion"])
        guard actual == expected else {
            throw WebDavError.malformedObject("设备心跳字段不匹配")
        }
        self.name = try container.decode(
            String.self,
            forKey: WebDavDeviceCodingKey("name")
        )
        self.platform = try container.decode(
            DevicePlatform.self,
            forKey: WebDavDeviceCodingKey("platform")
        )
        self.lastSeenAt = try container.decode(
            Int64.self,
            forKey: WebDavDeviceCodingKey("lastSeenAt")
        )
        self.appVersion = try container.decode(
            String.self,
            forKey: WebDavDeviceCodingKey("appVersion")
        )
        try validate()
    }

    public func validate() throws {
        guard (1...80).contains(name.unicodeScalars.count),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              lastSeenAt > 0,
              (1...32).contains(appVersion.unicodeScalars.count),
              appVersion.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WebDavError.malformedObject("设备心跳字段无效")
        }
    }

    public var lastSeenDate: Date {
        Date(timeIntervalSince1970: Double(lastSeenAt) / 1_000)
    }
}

/// `v1/<vaultId>/devices/<deviceId>.json` 的加密信封。
struct WebDavDeviceHeartbeatEnvelope: Codable, Equatable, Sendable {
    static let format = "woo-todo-webdav-device"
    static let protocolVersion = 1

    let format: String
    let protocolVersion: Int
    let deviceId: String
    let nonce: String
    let ciphertext: String

    init(deviceId: String, nonce: String, ciphertext: String) throws {
        self.format = Self.format
        self.protocolVersion = Self.protocolVersion
        self.deviceId = deviceId
        self.nonce = nonce
        self.ciphertext = ciphertext
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WebDavDeviceCodingKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        let expected = Set([
            "format", "protocolVersion", "deviceId", "nonce", "ciphertext",
        ])
        guard actual == expected else {
            throw WebDavError.malformedObject("设备心跳信封字段不匹配")
        }
        self.format = try container.decode(
            String.self,
            forKey: WebDavDeviceCodingKey("format")
        )
        self.protocolVersion = try container.decode(
            Int.self,
            forKey: WebDavDeviceCodingKey("protocolVersion")
        )
        self.deviceId = try container.decode(
            String.self,
            forKey: WebDavDeviceCodingKey("deviceId")
        )
        self.nonce = try container.decode(
            String.self,
            forKey: WebDavDeviceCodingKey("nonce")
        )
        self.ciphertext = try container.decode(
            String.self,
            forKey: WebDavDeviceCodingKey("ciphertext")
        )
        try validate()
    }

    func validate() throws {
        guard format == Self.format,
              protocolVersion == Self.protocolVersion,
              WebDavDeviceIdentifier.isValid(deviceId),
              (try? Base64URL.decode(nonce).count) == AES256GCM.nonceByteCount,
              (try? Base64URL.decode(ciphertext).count)
                .map({ $0 >= AES256GCM.tagByteCount }) == true else {
            throw WebDavError.malformedObject("设备心跳信封无效")
        }
    }

    static func path(vaultId: String, deviceId: String) -> [String] {
        ["v1", vaultId, "devices", "\(deviceId).json"]
    }
}

/// 接受任意字符串键，使 `allKeys` 能发现多余字段（String 枚举 CodingKey
/// 会把未知键丢成 nil），从而严格执行字段白名单。
private struct WebDavDeviceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue) }
}

/// 解密并校验后的设备信息，用于设备列表。
public struct WebDavDevice: Equatable, Sendable, Identifiable {
    public let deviceId: String
    public let name: String
    public let platform: DevicePlatform
    public let lastSeenAt: Date
    public let appVersion: String

    public var id: String { deviceId }
}

enum WebDavDeviceIdentifier {
    static func isValid(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$",
            options: .regularExpression
        ) != nil
    }
}

/// 设备心跳的加密、解密与 AAD 绑定。
enum WebDavDeviceHeartbeatCodec {
    static func aad(vaultId: String, deviceId: String) -> Data {
        Data("woo-todo-webdav-device-v1|\(vaultId)|\(deviceId)".utf8)
    }

    static func seal(
        _ heartbeat: WebDavDeviceHeartbeat,
        vaultId: String,
        deviceId: String,
        vaultKey: Data,
        nonce: Data? = nil
    ) throws -> WebDavDeviceHeartbeatEnvelope {
        try heartbeat.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext: Data
        do {
            plaintext = try encoder.encode(heartbeat)
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
        return try sealPlaintext(
            plaintext,
            vaultId: vaultId,
            deviceId: deviceId,
            vaultKey: vaultKey,
            nonce: nonce
        )
    }

    /// 供测试构造严格字段/篡改用例；生产写入只通过 `seal(_:)`。
    static func sealPlaintext(
        _ plaintext: Data,
        vaultId: String,
        deviceId: String,
        vaultKey: Data,
        nonce: Data? = nil
    ) throws -> WebDavDeviceHeartbeatEnvelope {
        do {
            let sealed = try AES256GCM.seal(
                plaintext,
                key: vaultKey,
                nonce: nonce,
                authenticating: aad(vaultId: vaultId, deviceId: deviceId)
            )
            return try WebDavDeviceHeartbeatEnvelope(
                deviceId: deviceId,
                nonce: sealed.nonce,
                ciphertext: sealed.ciphertext
            )
        } catch let error as WebDavError {
            throw error
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
    }

    static func open(
        _ envelope: WebDavDeviceHeartbeatEnvelope,
        vaultId: String,
        vaultKey: Data
    ) throws -> WebDavDeviceHeartbeat {
        try envelope.validate()
        let plaintext: Data
        do {
            plaintext = try AES256GCM.open(
                EncryptedEnvelope(
                    ciphertext: envelope.ciphertext,
                    nonce: envelope.nonce
                ),
                key: vaultKey,
                authenticating: aad(
                    vaultId: vaultId,
                    deviceId: envelope.deviceId
                )
            )
        } catch {
            throw WebDavError.malformedObject("设备心跳无法解密")
        }
        do {
            return try JSONDecoder().decode(WebDavDeviceHeartbeat.self, from: plaintext)
        } catch let error as WebDavError {
            throw error
        } catch {
            throw WebDavError.malformedObject("设备心跳明文无效")
        }
    }
}

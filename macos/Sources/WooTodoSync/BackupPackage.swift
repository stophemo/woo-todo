import CryptoKit
import Foundation

public enum BackupPackageError: Error, Equatable, LocalizedError {
    case invalidFile(String)
    case unsupportedVersion(Int)
    case invalidPassphrase
    case authenticationFailed
    case snapshotTooLarge
    case tooManyTasks
    case duplicateTaskID(String)
    case timestampMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let field): "备份文件的 \(field) 字段无效"
        case .unsupportedVersion(let version): "不支持备份协议版本：\(version)"
        case .invalidPassphrase: "备份口令规范化后须为 10～256 个字符"
        case .authenticationFailed: "备份口令错误或文件已损坏"
        case .snapshotTooLarge: "备份文件超过 32 MiB 限制"
        case .tooManyTasks: "备份中的任务数量超过 50000 条"
        case .duplicateTaskID(let id): "备份中存在重复任务 ID：\(id)"
        case .timestampMismatch: "备份外层与加密正文的导出时间不一致"
        }
    }
}

public struct BackupKDFParameters: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case algorithm
        case iterations
        case salt
    }

    public let algorithm: String
    public let iterations: Int
    public let salt: String

    public init(iterations: Int, salt: String) {
        self.algorithm = BackupPackageCodec.kdfAlgorithm
        self.iterations = iterations
        self.salt = salt
    }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(decoder, expected: ["algorithm", "iterations", "salt"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.algorithm = try container.decode(String.self, forKey: .algorithm)
        self.iterations = try container.decode(Int.self, forKey: .iterations)
        self.salt = try container.decode(String.self, forKey: .salt)
    }
}

public struct BackupCipherPayload: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case algorithm
        case nonce
        case ciphertext
    }

    public let algorithm: String
    public let nonce: String
    public let ciphertext: String

    public init(nonce: String, ciphertext: String) {
        self.algorithm = BackupPackageCodec.cipherAlgorithm
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(decoder, expected: ["algorithm", "nonce", "ciphertext"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.algorithm = try container.decode(String.self, forKey: .algorithm)
        self.nonce = try container.decode(String.self, forKey: .nonce)
        self.ciphertext = try container.decode(String.self, forKey: .ciphertext)
    }
}

public struct EncryptedBackupFile: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case createdAt
        case kdf
        case cipher
    }

    public let format: String
    public let version: Int
    public let createdAt: Int64
    public let kdf: BackupKDFParameters
    public let cipher: BackupCipherPayload

    public init(
        createdAt: Int64,
        kdf: BackupKDFParameters,
        cipher: BackupCipherPayload
    ) {
        self.format = BackupPackageCodec.fileFormat
        self.version = BackupPackageCodec.protocolVersion
        self.createdAt = createdAt
        self.kdf = kdf
        self.cipher = cipher
    }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            expected: ["format", "version", "createdAt", "kdf", "cipher"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try container.decode(String.self, forKey: .format)
        self.version = try container.decode(Int.self, forKey: .version)
        self.createdAt = try container.decode(Int64.self, forKey: .createdAt)
        self.kdf = try container.decode(BackupKDFParameters.self, forKey: .kdf)
        self.cipher = try container.decode(BackupCipherPayload.self, forKey: .cipher)
    }
}

public struct BackupSyncCredentials: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    private enum CodingKeys: String, CodingKey {
        case endpoint
        case vaultId
        case deviceId
        case deviceToken
        case vaultKey
    }

    public let endpoint: String
    public let vaultId: String
    public let deviceId: String
    public let deviceToken: String
    public let vaultKey: String

    public init(_ credentials: SyncCredentials) {
        self.endpoint = credentials.endpoint.absoluteString
        self.vaultId = credentials.vaultId
        self.deviceId = credentials.deviceId
        self.deviceToken = credentials.deviceToken
        self.vaultKey = Base64URL.encode(credentials.vaultKey)
    }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            expected: ["endpoint", "vaultId", "deviceId", "deviceToken", "vaultKey"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.endpoint = try container.decode(String.self, forKey: .endpoint)
        self.vaultId = try container.decode(String.self, forKey: .vaultId)
        self.deviceId = try container.decode(String.self, forKey: .deviceId)
        self.deviceToken = try container.decode(String.self, forKey: .deviceToken)
        self.vaultKey = try container.decode(String.self, forKey: .vaultKey)
    }

    public func credentials() throws -> SyncCredentials {
        guard let endpoint = URL(string: endpoint) else {
            throw BackupPackageError.invalidFile("syncCredentials.endpoint")
        }
        let value = SyncCredentials(
            endpoint: endpoint,
            vaultId: vaultId,
            deviceId: deviceId,
            deviceToken: deviceToken,
            vaultKey: try Base64URL.decode(vaultKey)
        )
        do {
            try value.validate()
        } catch {
            throw BackupPackageError.invalidFile("syncCredentials")
        }
        return value
    }

    public var description: String {
        "BackupSyncCredentials(endpoint: \(endpoint), vaultId: <redacted>, deviceId: <redacted>, secrets: <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct BackupSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case exportedAt
        case tasks
        case syncCredentials
    }

    public let protocolVersion: Int
    public let exportedAt: Int64
    public let tasks: [WireTaskPayload]
    public let syncCredentials: BackupSyncCredentials?

    public init(
        exportedAt: Int64,
        tasks: [WireTaskPayload],
        syncCredentials: BackupSyncCredentials?
    ) throws {
        self.protocolVersion = BackupPackageCodec.protocolVersion
        self.exportedAt = exportedAt
        self.tasks = tasks
        self.syncCredentials = syncCredentials
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            expected: ["protocolVersion", "exportedAt", "tasks", "syncCredentials"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        self.exportedAt = try container.decode(Int64.self, forKey: .exportedAt)
        self.tasks = try container.decode([WireTaskPayload].self, forKey: .tasks)
        self.syncCredentials = try container.decodeIfPresent(
            BackupSyncCredentials.self,
            forKey: .syncCredentials
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(tasks, forKey: .tasks)
        if let syncCredentials {
            try container.encode(syncCredentials, forKey: .syncCredentials)
        } else {
            try container.encodeNil(forKey: .syncCredentials)
        }
    }

    public func validate() throws {
        guard protocolVersion == BackupPackageCodec.protocolVersion else {
            throw BackupPackageError.unsupportedVersion(protocolVersion)
        }
        guard (0...WireTaskPayload.maximumSafeInteger).contains(exportedAt) else {
            throw BackupPackageError.invalidFile("exportedAt")
        }
        guard tasks.count <= BackupPackageCodec.maximumTaskCount else {
            throw BackupPackageError.tooManyTasks
        }
        var identifiers = Set<String>()
        for task in tasks {
            try task.validate()
            let canonicalID = task.id.lowercased()
            guard identifiers.insert(canonicalID).inserted else {
                throw BackupPackageError.duplicateTaskID(task.id)
            }
        }
        if let syncCredentials {
            _ = try syncCredentials.credentials()
        }
    }
}

public enum BackupKeyDerivation {
    public static func normalizedPassphrase(_ passphrase: String) throws -> String {
        let normalized = passphrase.precomposedStringWithCompatibilityMapping
        guard (10...256).contains(normalized.unicodeScalars.count) else {
            throw BackupPackageError.invalidPassphrase
        }
        return normalized
    }

    /// PBKDF2-HMAC-SHA256，口令以 NFKC 规范化后的 UTF-8 字节参与计算。
    public static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: Int,
        byteCount: Int = AES256GCM.keyByteCount
    ) throws -> Data {
        guard salt.count == BackupPackageCodec.saltByteCount else {
            throw BackupPackageError.invalidFile("kdf.salt")
        }
        guard BackupPackageCodec.allowedIterations.contains(iterations), byteCount > 0 else {
            throw BackupPackageError.invalidFile("kdf.iterations")
        }
        let normalized = try normalizedPassphrase(passphrase)
        let key = SymmetricKey(data: Data(normalized.utf8))
        var result = Data()
        var blockIndex: UInt32 = 1

        while result.count < byteCount {
            var counter = blockIndex.bigEndian
            var initial = salt
            withUnsafeBytes(of: &counter) { initial.append(contentsOf: $0) }
            var previous = Data(HMAC<SHA256>.authenticationCode(for: initial, using: key))
            var accumulated = previous

            if iterations > 1 {
                for _ in 1..<iterations {
                    previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: key))
                    accumulated.withUnsafeMutableBytes { accumulatedBuffer in
                        previous.withUnsafeBytes { previousBuffer in
                            let output = accumulatedBuffer.bindMemory(to: UInt8.self)
                            let input = previousBuffer.bindMemory(to: UInt8.self)
                            for index in 0..<output.count {
                                output[index] ^= input[index]
                            }
                        }
                    }
                }
            }
            result.append(accumulated)
            blockIndex = blockIndex.addingReportingOverflow(1).partialValue
            guard blockIndex != 0 else {
                throw BackupPackageError.invalidFile("kdf.outputLength")
            }
        }
        return result.prefix(byteCount)
    }
}

public enum BackupPackageCodec {
    public static let fileFormat = "woo-todo-backup"
    public static let protocolVersion = 1
    public static let kdfAlgorithm = "pbkdf2-hmac-sha256"
    public static let cipherAlgorithm = "aes-256-gcm"
    public static let aadNamespace = "woo-todo-backup-v1"
    public static let defaultIterations = 210_000
    public static let allowedIterations = 100_000...2_000_000
    public static let saltByteCount = 16
    public static let maximumTaskCount = 50_000
    public static let maximumCiphertextByteCount = 32 * 1024 * 1024
    public static let maximumFileByteCount = 45 * 1024 * 1024

    public static func seal(
        _ snapshot: BackupSnapshot,
        passphrase: String,
        iterations: Int = defaultIterations,
        salt: Data? = nil,
        nonce: Data? = nil
    ) throws -> Data {
        try snapshot.validate()
        guard allowedIterations.contains(iterations) else {
            throw BackupPackageError.invalidFile("kdf.iterations")
        }
        let actualSalt = try salt ?? SecureRandom.bytes(count: saltByteCount)
        guard actualSalt.count == saltByteCount else {
            throw BackupPackageError.invalidFile("kdf.salt")
        }
        let key = try BackupKeyDerivation.deriveKey(
            passphrase: passphrase,
            salt: actualSalt,
            iterations: iterations
        )
        let kdf = BackupKDFParameters(
            iterations: iterations,
            salt: Base64URL.encode(actualSalt)
        )
        let plaintext = try encoder().encode(snapshot)
        guard plaintext.count <= maximumCiphertextByteCount - AES256GCM.tagByteCount else {
            throw BackupPackageError.snapshotTooLarge
        }
        let envelope = try AES256GCM.seal(
            plaintext,
            key: key,
            nonce: nonce,
            authenticating: additionalAuthenticatedData(
                createdAt: snapshot.exportedAt,
                kdf: kdf
            )
        )
        let file = EncryptedBackupFile(
            createdAt: snapshot.exportedAt,
            kdf: kdf,
            cipher: BackupCipherPayload(
                nonce: envelope.nonce,
                ciphertext: envelope.ciphertext
            )
        )
        let data = try encoder().encode(file)
        guard data.count <= maximumFileByteCount else {
            throw BackupPackageError.snapshotTooLarge
        }
        return data
    }

    public static func open(_ data: Data, passphrase: String) throws -> BackupSnapshot {
        guard data.count <= maximumFileByteCount else {
            throw BackupPackageError.snapshotTooLarge
        }
        try StrictBackupJSON.validate(data)
        let file = try decoder().decode(EncryptedBackupFile.self, from: data)
        try validate(file)
        let salt = try Base64URL.decode(file.kdf.salt)
        let combined = try Base64URL.decode(file.cipher.ciphertext)
        guard combined.count <= maximumCiphertextByteCount else {
            throw BackupPackageError.snapshotTooLarge
        }
        let key = try BackupKeyDerivation.deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: file.kdf.iterations
        )
        let plaintext: Data
        do {
            plaintext = try AES256GCM.open(
                EncryptedEnvelope(
                    ciphertext: file.cipher.ciphertext,
                    nonce: file.cipher.nonce
                ),
                key: key,
                authenticating: additionalAuthenticatedData(
                    createdAt: file.createdAt,
                    kdf: file.kdf
                )
            )
        } catch {
            throw BackupPackageError.authenticationFailed
        }
        try StrictBackupJSON.validate(plaintext)
        let snapshot = try decoder().decode(BackupSnapshot.self, from: plaintext)
        guard snapshot.exportedAt == file.createdAt else {
            throw BackupPackageError.timestampMismatch
        }
        return snapshot
    }

    public static func canonicalAAD(
        createdAt: Int64,
        kdf: BackupKDFParameters
    ) -> String {
        [
            aadNamespace,
            String(createdAt),
            kdf.algorithm,
            String(kdf.iterations),
            kdf.salt,
            cipherAlgorithm,
        ].joined(separator: "|")
    }

    public static func additionalAuthenticatedData(
        createdAt: Int64,
        kdf: BackupKDFParameters
    ) -> Data {
        Data(canonicalAAD(createdAt: createdAt, kdf: kdf).utf8)
    }

    private static func validate(_ file: EncryptedBackupFile) throws {
        guard file.format == fileFormat else {
            throw BackupPackageError.invalidFile("format")
        }
        guard file.version == protocolVersion else {
            throw BackupPackageError.unsupportedVersion(file.version)
        }
        guard (0...WireTaskPayload.maximumSafeInteger).contains(file.createdAt) else {
            throw BackupPackageError.invalidFile("createdAt")
        }
        guard file.kdf.algorithm == kdfAlgorithm,
              allowedIterations.contains(file.kdf.iterations),
              (try? Base64URL.decode(file.kdf.salt).count) == saltByteCount else {
            throw BackupPackageError.invalidFile("kdf")
        }
        guard file.cipher.algorithm == cipherAlgorithm,
              (try? Base64URL.decode(file.cipher.nonce).count) == AES256GCM.nonceByteCount,
              (try? Base64URL.decode(file.cipher.ciphertext).count) ?? 0
                >= AES256GCM.tagByteCount else {
            throw BackupPackageError.invalidFile("cipher")
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

private struct AnyCodingKey: CodingKey {
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

private func requireExactKeys(_ decoder: Decoder, expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "JSON 字段不匹配，期望 \(expected)，实际 \(actual)"
            )
        )
    }
}

/// JSONDecoder 会接受重复对象键；备份协议先做结构扫描，避免不同平台选择不同值。
private struct StrictBackupJSON {
    private let bytes: [UInt8]
    private var index = 0

    static func validate(_ data: Data) throws {
        var parser = StrictBackupJSON(bytes: Array(data))
        do {
            try parser.parseValue(depth: 0)
            parser.skipWhitespace()
            guard parser.index == parser.bytes.count else { throw ParseError.invalid }
        } catch {
            throw BackupPackageError.invalidFile("json")
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= 64 else { throw ParseError.invalid }
        skipWhitespace()
        guard let byte = current else { throw ParseError.invalid }
        switch byte {
        case 0x7B: try parseObject(depth: depth + 1) // {
        case 0x5B: try parseArray(depth: depth + 1) // [
        case 0x22: _ = try scanString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6E: try consumeLiteral("null")
        case 0x2D, 0x30...0x39: try parseNumber()
        default: throw ParseError.invalid
        }
    }

    private mutating func parseObject(depth: Int) throws {
        try expect(0x7B)
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7D) { return }
        while true {
            skipWhitespace()
            let keyData = try scanString()
            let key = try JSONDecoder().decode(String.self, from: keyData)
            guard keys.insert(key).inserted else { throw ParseError.invalid }
            skipWhitespace()
            try expect(0x3A)
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return }
            try expect(0x2C)
        }
    }

    private mutating func parseArray(depth: Int) throws {
        try expect(0x5B)
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x5D) { return }
            try expect(0x2C)
        }
    }

    private mutating func scanString() throws -> Data {
        let start = index
        try expect(0x22)
        while let byte = current {
            index += 1
            switch byte {
            case 0x22:
                return Data(bytes[start..<index])
            case 0x5C:
                guard let escaped = current else { throw ParseError.invalid }
                index += 1
                if escaped == 0x75 {
                    guard index + 4 <= bytes.count,
                          bytes[index..<(index + 4)].allSatisfy(Self.isHex) else {
                        throw ParseError.invalid
                    }
                    index += 4
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    throw ParseError.invalid
                }
            case 0x00...0x1F:
                throw ParseError.invalid
            default:
                continue
            }
        }
        throw ParseError.invalid
    }

    private mutating func parseNumber() throws {
        _ = consume(0x2D)
        guard let byte = current else { throw ParseError.invalid }
        if byte == 0x30 {
            index += 1
            if current.map(Self.isDigit) == true { throw ParseError.invalid }
        } else {
            guard (0x31...0x39).contains(byte) else { throw ParseError.invalid }
            consumeDigits()
        }
        if consume(0x2E) {
            guard current.map(Self.isDigit) == true else { throw ParseError.invalid }
            consumeDigits()
        }
        if current == 0x65 || current == 0x45 {
            index += 1
            if current == 0x2B || current == 0x2D { index += 1 }
            guard current.map(Self.isDigit) == true else { throw ParseError.invalid }
            consumeDigits()
        }
    }

    private mutating func consumeDigits() {
        while current.map(Self.isDigit) == true { index += 1 }
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let expected = literal.withUTF8Buffer { Array($0) }
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw ParseError.invalid
        }
        index += expected.count
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw ParseError.invalid }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            index += 1
        }
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private enum ParseError: Error {
        case invalid
    }
}

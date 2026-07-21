import Foundation
import Testing
@testable import WooTodoSync

@Suite("加密备份协议", .serialized)
struct BackupPackageTests {
    @Test("共享 golden vector 锁定 NFKC、PBKDF2、AAD 与密文")
    func test共享GoldenVector() throws {
        let vector = try loadFixture()
        let salt = try Base64URL.decode(vector.kdf.salt)
        let nonce = try Base64URL.decode(vector.cipher.nonce)
        let key = try BackupKeyDerivation.deriveKey(
            passphrase: vector.password,
            salt: salt,
            iterations: vector.kdf.iterations
        )
        #expect(
            try BackupKeyDerivation.normalizedPassphrase(vector.password)
                == vector.passwordNormalized
        )
        #expect(Base64URL.encode(key) == vector.derivedKey)

        let kdf = BackupKDFParameters(iterations: vector.kdf.iterations, salt: vector.kdf.salt)
        #expect(
            BackupPackageCodec.canonicalAAD(createdAt: vector.createdAt, kdf: kdf)
                == vector.aadUtf8
        )
        let snapshotData = Data(vector.plaintextUtf8.utf8)
        let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: snapshotData)
        let package = try BackupPackageCodec.seal(
            snapshot,
            passphrase: vector.password,
            iterations: vector.kdf.iterations,
            salt: salt,
            nonce: nonce
        )
        let file = try JSONDecoder().decode(EncryptedBackupFile.self, from: package)
        #expect(file.cipher.ciphertext == vector.cipher.ciphertext)
        #expect(try BackupPackageCodec.open(package, passphrase: vector.password) == snapshot)
        #expect(snapshot.tombstones.isEmpty)
        #expect(snapshot.tasks.first?.title == "提交周报")
        #expect(try snapshot.syncCredentials?.credentials().vaultId == "vault-backup-1")
    }

    @Test("旧备份缺失删除字段仍可读取，新备份保留 tombstone")
    func test备份删除屏障兼容() throws {
        let vector = try loadFixture()
        let legacy = try JSONDecoder().decode(
            BackupSnapshot.self,
            from: Data(vector.plaintextUtf8.utf8)
        )
        #expect(legacy.tombstones.isEmpty)

        let snapshot = try JSONDecoder().decode(
            BackupSnapshot.self,
            from: Data(vector.tombstonePlaintextUtf8.utf8)
        )
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.tombstones.count == 1)
        #expect(snapshot.tombstones[0].deletedAt == 1_784_251_800_000)

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"tombstones\""))
        let legacyEncoded = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: legacyEncoded, as: UTF8.self).contains("\"tombstones\""))

        var invalid = try #require(
            JSONSerialization.jsonObject(with: Data(vector.plaintextUtf8.utf8))
                as? [String: Any]
        )
        invalid["tombstones"] = NSNull()
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                BackupSnapshot.self,
                from: JSONSerialization.data(withJSONObject: invalid)
            )
        }

        let package = try BackupPackageCodec.seal(
            snapshot,
            passphrase: vector.password,
            iterations: vector.kdf.iterations,
            salt: try Base64URL.decode(vector.kdf.salt),
            nonce: try Base64URL.decode(vector.cipher.nonce)
        )
        #expect(try BackupPackageCodec.open(package, passphrase: vector.password) == snapshot)
    }

    @Test("备份往返保留任务提醒时间")
    func test备份提醒时间往返() throws {
        let vector = try loadFixture()
        let task = try WireTaskPayload(
            id: "550e8400-e29b-41d4-a716-446655440000",
            seriesId: "550e8400-e29b-41d4-a716-446655440000",
            title: "带提醒任务",
            timeType: .day,
            periodStart: "2026-07-21",
            timezone: "Asia/Shanghai",
            questLine: .main,
            state: .pending,
            recurrence: .once,
            sortOrder: 0,
            createdAt: 1,
            updatedAt: 1,
            reminderTime: "08:30",
            settledAt: nil
        )
        let snapshot = try BackupSnapshot(
            exportedAt: vector.createdAt,
            tasks: [task],
            syncCredentials: nil
        )
        let package = try BackupPackageCodec.seal(
            snapshot,
            passphrase: vector.password,
            iterations: vector.kdf.iterations,
            salt: try Base64URL.decode(vector.kdf.salt),
            nonce: try Base64URL.decode(vector.cipher.nonce)
        )

        #expect(
            try BackupPackageCodec.open(package, passphrase: vector.password)
                .tasks.first?.reminderTime == "08:30"
        )
    }

    @Test("任务与删除记录不能使用相同实体 ID")
    func test备份实体ID跨数组唯一() throws {
        let vector = try loadFixture()
        let legacy = try JSONDecoder().decode(
            BackupSnapshot.self,
            from: Data(vector.plaintextUtf8.utf8)
        )
        let task = try #require(legacy.tasks.first)
        let tombstone = try WireTombstonePayload(id: task.id, deletedAt: vector.createdAt)
        #expect(throws: BackupPackageError.duplicateTaskID(task.id)) {
            try BackupSnapshot(
                exportedAt: vector.createdAt,
                tasks: [task],
                tombstones: [tombstone],
                syncCredentials: nil
            )
        }
    }

    @Test("错误口令与篡改密文均被拒绝")
    func test错误口令与篡改密文均被拒绝() throws {
        let vector = try loadFixture()
        let file = EncryptedBackupFile(
            createdAt: vector.createdAt,
            kdf: BackupKDFParameters(
                iterations: vector.kdf.iterations,
                salt: vector.kdf.salt
            ),
            cipher: BackupCipherPayload(
                nonce: vector.cipher.nonce,
                ciphertext: vector.cipher.ciphertext
            )
        )
        let data = try JSONEncoder().encode(file)
        #expect(throws: BackupPackageError.authenticationFailed) {
            try BackupPackageCodec.open(data, passphrase: "这是一个完全错误的口令")
        }

        var bytes = try Base64URL.decode(file.cipher.ciphertext)
        bytes[0] ^= 1
        let tampered = EncryptedBackupFile(
            createdAt: file.createdAt,
            kdf: file.kdf,
            cipher: BackupCipherPayload(
                nonce: file.cipher.nonce,
                ciphertext: Base64URL.encode(bytes)
            )
        )
        #expect(throws: BackupPackageError.authenticationFailed) {
            try BackupPackageCodec.open(
                JSONEncoder().encode(tampered),
                passphrase: vector.password
            )
        }
    }

    @Test("备份 JSON 拒绝未知字段与重复键")
    func test严格JSON() throws {
        let vector = try loadFixture()
        let file = EncryptedBackupFile(
            createdAt: vector.createdAt,
            kdf: BackupKDFParameters(
                iterations: vector.kdf.iterations,
                salt: vector.kdf.salt
            ),
            cipher: BackupCipherPayload(
                nonce: vector.cipher.nonce,
                ciphertext: vector.cipher.ciphertext
            )
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any]
        )
        object["unexpected"] = true
        #expect(throws: (any Error).self) {
            try BackupPackageCodec.open(
                JSONSerialization.data(withJSONObject: object),
                passphrase: vector.password
            )
        }

        let source = try #require(String(data: JSONEncoder().encode(file), encoding: .utf8))
        let duplicate = source.replacingOccurrences(
            of: "{",
            with: "{\"format\":\"woo-todo-backup\",",
            options: [],
            range: source.startIndex..<source.index(after: source.startIndex)
        )
        #expect(throws: (any Error).self) {
            try BackupPackageCodec.open(Data(duplicate.utf8), passphrase: vector.password)
        }
    }

    private func loadFixture() throws -> BackupFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            BackupFixture.self,
            from: Data(
                contentsOf: repositoryRoot
                    .appendingPathComponent("shared")
                    .appendingPathComponent("fixtures")
                    .appendingPathComponent("backup-vectors.json")
            )
        )
    }
}

private struct BackupFixture: Decodable {
    let password: String
    let passwordNormalized: String
    let createdAt: Int64
    let kdf: KDF
    let cipher: Cipher
    let aadUtf8: String
    let derivedKey: String
    let plaintextUtf8: String
    let tombstonePlaintextUtf8: String

    struct KDF: Decodable {
        let iterations: Int
        let salt: String
    }

    struct Cipher: Decodable {
        let nonce: String
        let ciphertext: String
    }
}

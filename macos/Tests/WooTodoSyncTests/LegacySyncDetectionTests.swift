import Foundation
import Testing
@testable import WooTodoSync

@Suite("旧同步方式检测")
struct LegacySyncDetectionTests {
    @Test("旧 endpoint 凭据读取失败会被视为 legacy")
    func invalidEndpointCredentialsAreLegacy() {
        #expect(SyncLegacyDetector.isLegacyCredentialsError(
            CredentialsStoreError.invalidCredentials
        ))
        #expect(SyncLegacyDetector.isLegacyCredentialsError(
            EncryptedFileSyncCredentialsStoreError.invalidCredentialsFile
        ))
        #expect(!SyncLegacyDetector.isLegacyCredentialsError(
            CredentialsStoreError.keychain(-25300)
        ))
        #expect(!SyncLegacyDetector.isLegacyCredentialsError(nil))
    }

    @Test("旧 WebDAV 凭据文件与局域网状态目录会被识别")
    func legacyStorageFilesAreDetected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secure = root.appendingPathComponent("Secure", isDirectory: true)
        try FileManager.default.createDirectory(at: secure, withIntermediateDirectories: true)

        #expect(!SyncLegacyDetector.detect(
            credentialsError: nil,
            applicationSupportURL: root
        ).isLegacy)

        try Data("legacy".utf8).write(
            to: secure.appendingPathComponent("webdav-credentials.enc")
        )
        let detection = SyncLegacyDetector.detect(
            credentialsError: nil,
            applicationSupportURL: root
        )
        #expect(detection.legacyStoragePresent)
        #expect(detection.isLegacy)

        try FileManager.default.removeItem(
            at: secure.appendingPathComponent("webdav-credentials.enc")
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("local-sync", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(SyncLegacyDetector.detect(
            credentialsError: nil,
            applicationSupportURL: root
        ).legacyStoragePresent)
    }

    @Test("旧凭据错误与文件存在合并为一次性提示条件")
    func combinedDetection() {
        let detection = SyncLegacyDetection(
            credentialsInvalidated: true,
            legacyStoragePresent: false
        )
        #expect(detection.isLegacy)
        #expect(!SyncLegacyDetection(
            credentialsInvalidated: false,
            legacyStoragePresent: false
        ).isLegacy)
    }

    @Test("有效新凭据与旧文件并存时仍正常激活，只提示旧方式")
    func validCredentialsWinOverLegacyFiles() throws {
        let root = try makeLegacyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try makeCredentials()

        let decision = SyncStartupActivationPolicy.evaluate(
            storedCredentials: credentials,
            credentialsError: nil,
            applicationSupportURL: root
        )
        #expect(decision.activeCredentials == credentials)
        #expect(decision.activationError == nil)
        #expect(decision.hasStoredValidCredentials)
        #expect(decision.legacyDetection.legacyStoragePresent)
        #expect(decision.shouldShowLegacyNotice == false)
    }

    @Test("已保存凭据 endpoint 不合法时视为 legacy 且不激活")
    func invalidStoredEndpointIsLegacy() throws {
        let credentials = SyncCredentials(
            endpoint: try #require(URL(string: "https://192.168.1.2")),
            vaultId: "vault-test",
            deviceId: "device-test",
            deviceToken: Base64URL.encode(Data(repeating: 1, count: 32)),
            vaultKey: Data(repeating: 7, count: 32)
        )
        let decision = SyncStartupActivationPolicy.evaluate(
            storedCredentials: credentials,
            credentialsError: nil,
            applicationSupportURL: nil
        )
        #expect(decision.activeCredentials == nil)
        #expect(decision.activationError == nil)
        #expect(decision.legacyDetection.credentialsInvalidated)
        #expect(decision.shouldShowLegacyNotice)
    }

    @Test("旧凭据读取失败不激活且不产生凭据警告")
    func legacyCredentialErrorIsNoticeOnly() {
        let decision = SyncStartupActivationPolicy.evaluate(
            storedCredentials: nil,
            credentialsError: CredentialsStoreError.invalidCredentials,
            applicationSupportURL: nil
        )
        #expect(decision.activeCredentials == nil)
        #expect(decision.activationError == nil)
        #expect(decision.legacyDetection.credentialsInvalidated)
        #expect(decision.shouldShowLegacyNotice)
    }

    @Test("密钥或文件系统错误不激活并回传凭据警告")
    func keychainErrorSurfacesActivationWarning() {
        let error = EncryptedFileSyncCredentialsStoreError.keychainUnavailable("locked")
        let decision = SyncStartupActivationPolicy.evaluate(
            storedCredentials: nil,
            credentialsError: error,
            applicationSupportURL: nil
        )
        #expect(decision.activeCredentials == nil)
        #expect(decision.activationError != nil)
        #expect(!decision.legacyDetection.credentialsInvalidated)
        #expect(decision.shouldShowLegacyNotice == false)
    }

    private func makeCredentials() throws -> SyncCredentials {
        SyncCredentials(
            endpoint: try #require(URL(string: "https://sync.example.test")),
            vaultId: "vault-test",
            deviceId: "device-test",
            deviceToken: Base64URL.encode(Data(repeating: 1, count: 32)),
            vaultKey: Data(repeating: 7, count: 32)
        )
    }

    private func makeLegacyRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-legacy-\(UUID().uuidString)", isDirectory: true)
        let secure = root.appendingPathComponent("Secure", isDirectory: true)
        try FileManager.default.createDirectory(at: secure, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(
            to: secure.appendingPathComponent("webdav-credentials.enc")
        )
        return root
    }
}

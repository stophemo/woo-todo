import Foundation
import Testing
@testable import WooTodoSync

@Suite("配对深链")
struct PairingDeepLinkTests {
    @Test("深链构造和解析严格往返且日志描述隐藏凭据")
    func roundTripAndRedaction() throws {
        let secret = Base64URL.encode(Data(repeating: 1, count: 32))
        let publicKey = Base64URL.encode(Data(repeating: 2, count: 32))
        let value = try PairingDeepLink(
            endpoint: URL(string: "https://sync.example.test/base")!,
            pairingId: "pair-demo-001",
            pairingSecret: secret,
            initiatorPublicKey: publicKey
        )
        let url = try value.url()
        let parsed = try PairingDeepLink(url: url)
        #expect(parsed == value)
        #expect(url.scheme == "wootodo")
        #expect(url.host == "pair")
        #expect(!value.description.contains(secret))
        #expect(!value.description.contains(publicKey))
    }

    @Test("生产拒绝 HTTP 但允许 127.0.0.1 本地调试")
    func endpointPolicy() throws {
        let secret = Base64URL.encode(Data(repeating: 1, count: 32))
        let publicKey = Base64URL.encode(Data(repeating: 2, count: 32))
        #expect(throws: PairingDeepLinkError.invalidEndpoint) {
            _ = try PairingDeepLink(
                endpoint: URL(string: "http://sync.example.test")!,
                pairingId: "pair-1",
                pairingSecret: secret,
                initiatorPublicKey: publicKey
            )
        }
        let local = try PairingDeepLink(
            endpoint: URL(string: "http://127.0.0.1:8787")!,
            pairingId: "pair-1",
            pairingSecret: secret,
            initiatorPublicKey: publicKey
        )
        #expect(local.endpoint.host == "127.0.0.1")
    }
}

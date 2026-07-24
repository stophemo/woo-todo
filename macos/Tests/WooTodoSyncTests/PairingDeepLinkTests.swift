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

    @Test("公网拒绝 HTTP，但允许回环调试与受限局域网地址")
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

        let privateNetwork = try PairingDeepLink(
            endpoint: URL(string: "http://192.168.8.21:48473")!,
            pairingId: "pair-private",
            pairingSecret: secret,
            initiatorPublicKey: publicKey
        )
        #expect(SyncEndpointPolicy.scope(of: privateNetwork.endpoint) == .localNetwork)
        #expect(
            SyncEndpointPolicy.scope(of: URL(string: "http://woo-mac.local:48473")!)
                == .localNetwork
        )
        #expect(
            SyncEndpointPolicy.scope(of: URL(string: "http://172.15.255.255:48473")!)
                == .invalid
        )
        #expect(
            SyncEndpointPolicy.scope(of: URL(string: "http://172.32.0.1:48473")!)
                == .invalid
        )
    }

    @Test("创建双端空间时拒绝回环地址与 API 子路径")
    func crossDeviceSetupPolicy() {
        #expect(SyncEndpointSetupPolicy.assess("   ") == .empty)
        #expect(SyncEndpointSetupPolicy.assess("sync.example.test") == .invalid)
        #expect(
            SyncEndpointSetupPolicy.assess("http://127.0.0.1:8787") == .currentDeviceOnly
        )
        #expect(
            SyncEndpointSetupPolicy.assess("https://localhost:8787") == .currentDeviceOnly
        )
        #expect(
            SyncEndpointSetupPolicy.assess("http://192.168.8.21:48473") == .invalid
        )
        #expect(
            SyncEndpointSetupPolicy.assess("https://sync.example.test/v1") == .includesAPIVersion
        )
        #expect(
            SyncEndpointSetupPolicy.assess(" https://sync.example.test/root ")
                == .ready(URL(string: "https://sync.example.test/root")!)
        )
    }
}

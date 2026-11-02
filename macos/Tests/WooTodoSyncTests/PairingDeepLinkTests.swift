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

    @Test("局域网地址优先使用可随 IP 变化解析的本地主机名")
    func localEndpointCandidatesPreferStableHostname() {
        #expect(
            LocalNetworkSyncEndpointResolver.candidateHosts(
                localHost: "woo-mac.local",
                privateIPv4: "192.168.43.12"
            ) == ["woo-mac.local", "192.168.43.12"]
        )
        #expect(
            LocalNetworkSyncEndpointResolver.candidateHosts(
                localHost: "woo-mac.local",
                privateIPv4: nil
            ) == ["woo-mac.local"]
        )
    }

    @Test("Bonjour 仅公布不可逆的同步空间指纹")
    func localNetworkVaultFingerprint() {
        #expect(
            LocalNetworkSyncConstants.vaultFingerprint("vault-local-network")
                == "RfUwop7bTtqyqSTnYPOC59GEb1TR5lF0zufaM5aoNGE"
        )
    }

    @Test("Mac 主机通过回环访问局域网服务且保留对外端口")
    func localHostClientEndpointUsesLoopback() throws {
        let advertised = try #require(URL(string: "http://10.100.68.172:48473"))
        let hostClient = LocalNetworkSyncEndpointResolver.hostClientEndpoint(
            for: advertised
        )
        #expect(hostClient == URL(string: "http://127.0.0.1:48473"))

        let remote = try #require(URL(string: "https://sync.example.test/root"))
        #expect(
            LocalNetworkSyncEndpointResolver.hostClientEndpoint(for: remote) == remote
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

    @Test("配对深链携带备选地址并按顺序去重")
    func alternateEndpointsRoundTrip() throws {
        let secret = Base64URL.encode(Data(repeating: 3, count: 32))
        let publicKey = Base64URL.encode(Data(repeating: 4, count: 32))
        let primary = URL(string: "http://stophemo.local:48473")!
        let value = try PairingDeepLink(
            endpoint: primary,
            alternateEndpoints: [
                URL(string: "http://192.168.43.12:48473")!,
                URL(string: "http://192.168.2.1:48473")!,
                primary,
            ],
            pairingId: "pair-demo-002",
            pairingSecret: secret,
            initiatorPublicKey: publicKey
        )
        let url = try value.url()
        let parsed = try PairingDeepLink(url: url)
        #expect(parsed.endpoint == primary)
        #expect(
            parsed.alternateEndpoints.map(\.absoluteString)
                == ["http://192.168.43.12:48473", "http://192.168.2.1:48473"]
        )
        #expect(parsed == value)
    }

    @Test("备选地址必须也是局域网地址且不与主地址重复占位")
    func alternateEndpointsValidation() throws {
        let secret = Base64URL.encode(Data(repeating: 5, count: 32))
        let publicKey = Base64URL.encode(Data(repeating: 6, count: 32))
        #expect(throws: PairingDeepLinkError.invalidEndpoint) {
            _ = try PairingDeepLink(
                endpoint: URL(string: "http://192.168.1.10:48473")!,
                alternateEndpoints: [URL(string: "http://example.com")!],
                pairingId: "pair-demo-003",
                pairingSecret: secret,
                initiatorPublicKey: publicKey
            )
        }
    }

    @Test("非 alt 字段重复仍然被拒绝")
    func duplicateNonAlternateFieldRejected() throws {
        let secret = Base64URL.encode(Data(repeating: 7, count: 32))
        let publicKey = Base64URL.encode(Data(repeating: 8, count: 32))
        let raw = "wootodo://pair?endpoint=http%3A%2F%2F192.168.1.10%3A48473"
            + "&pairingId=a&pairingId=b"
            + "&pairingSecret=\(secret)&initiatorPublicKey=\(publicKey)"
        #expect(throws: PairingDeepLinkError.duplicateOrUnknownField) {
            _ = try PairingDeepLink(url: URL(string: raw)!)
        }
    }

    @Test("局域网候选地址按 Wi-Fi、桥接、其他网卡排序")
    func candidateHostOrdering() {
        #expect(
            LocalNetworkSyncEndpointResolver.candidateHosts(
                localHost: "mac.local",
                privateIPv4s: ["192.168.2.1", "10.0.0.9"]
            ) == ["mac.local", "192.168.2.1", "10.0.0.9"]
        )
        #expect(
            LocalNetworkSyncEndpointResolver.candidateHosts(localHost: nil, privateIPv4s: [])
                .isEmpty
        )
    }
}

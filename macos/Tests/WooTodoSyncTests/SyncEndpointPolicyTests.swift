import Foundation
import Testing
@testable import WooTodoSync

@Suite("跨设备 Endpoint 策略")
struct SyncEndpointPolicyTests {
    @Test("只允许公网 HTTPS 根地址")
    func allowsOnlyPublicHTTPSRoot() throws {
        #expect(SyncEndpointPolicy.isAllowed(
            try #require(URL(string: "https://sync.example.test"))
        ))
        #expect(SyncEndpointPolicy.isAllowed(
            try #require(URL(string: "https://sync.example.test/"))
        ))
        #expect(SyncEndpointPolicy.isAllowed(
            try #require(URL(string: "https://172.32.0.1"))
        ))
        #expect(SyncEndpointPolicy.isAllowed(
            try #require(URL(string: "https://8.8.8.8"))
        ))
        #expect(SyncEndpointPolicy.isAllowed(
            try #require(URL(string: "https://100.128.0.1"))
        ))
        #expect(SyncEndpointPolicy.isAllowed(
            try #require(URL(string: "https://[2606:4700:4700::1111]"))
        ))

        for source in [
            "http://sync.example.test",
            "https://sync.example.test/root",
            "https://sync.example.test/v1",
            "https://user@sync.example.test",
            "https://sync.example.test/?query=1",
            "https://sync.example.test/#fragment",
        ] {
            #expect(!SyncEndpointPolicy.isAllowed(
                try #require(URL(string: source))
            ), "\(source) 不应被允许")
        }
    }

    @Test("拒绝回环、链路本地、私网与 IPv6 特殊地址")
    func rejectsLocalAndPrivateHosts() throws {
        for source in [
            "https://127.0.0.1",
            "https://127.0.0.2",
            "https://127.255.255.254",
            "https://localhost",
            "https://localhost.",
            "https://sync.localhost",
            "https://[::1]",
            "https://[::]",
            "https://0.0.0.0",
            "https://0.1.2.3",
            "https://169.254.169.254",
            "https://100.64.0.1",
            "https://100.127.255.255",
            "https://10.1.2.3",
            "https://192.168.8.21",
            "https://172.16.0.1",
            "https://172.31.255.255",
            "https://[fc00::1]",
            "https://[fd12:3456::1]",
            "https://[fe80::1]",
            "https://[::ffff:192.168.1.1]",
            "https://[::ffff:127.0.0.1]",
            "https://woo-mac.local",
        ] {
            #expect(!SyncEndpointPolicy.isAllowed(
                try #require(URL(string: source))
            ), "\(source) 不应被允许")
        }
    }

    @Test("拒绝非规范数值主机写法，避免本地或未指定地址绕过")
    func rejectsNonCanonicalNumericHosts() throws {
        for source in [
            "https://127.1",
            "https://2130706433",
            "https://0127.0.0.1",
            "https://127.0.0.01",
            "https://127.000.000.001",
            "https://0x7f000001",
            "https://0X7F000001",
            "https://0x7f.0.0.1",
            "https://0",
            "https://127..0.1",
            "https://1.2.3.4.5",
        ] {
            #expect(!SyncEndpointPolicy.isAllowed(
                try #require(URL(string: source))
            ), "\(source) 不应被允许")
        }

        // 合法域名与规范四段公网 IP 仍然通过。
        for source in [
            "https://sync.example.test",
            "https://example.com",
            "https://8.8.8.8",
            "https://1.1.1.1",
        ] {
            #expect(SyncEndpointPolicy.isAllowed(
                try #require(URL(string: source))
            ), "\(source) 应被允许")
        }
    }

    @Test("设置页评估区分空、无效、误填 /v1 与可用地址")
    func setupAssessment() throws {
        #expect(SyncEndpointSetupPolicy.assess("   ") == .empty)
        #expect(SyncEndpointSetupPolicy.assess("sync.example.test") == .invalid)
        #expect(SyncEndpointSetupPolicy.assess("http://sync.example.test") == .invalid)
        #expect(
            SyncEndpointSetupPolicy.assess("https://sync.example.test/root") == .invalid
        )
        #expect(
            SyncEndpointSetupPolicy.assess("https://sync.example.test/v1")
                == .includesAPIVersion
        )
        #expect(
            SyncEndpointSetupPolicy.assess(" https://sync.example.test ")
                == .ready(try #require(URL(string: "https://sync.example.test")))
        )
        #expect(
            SyncEndpointSetupPolicy.assess("http://192.168.8.21:48473") == .invalid
        )
    }
}

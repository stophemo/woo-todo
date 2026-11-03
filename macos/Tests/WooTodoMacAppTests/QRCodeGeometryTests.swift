import AppKit
import Testing
@testable import WooTodoMacApp

@Suite("配对二维码几何")
struct QRCodeGeometryTests {
    /// 真实配对串的量级：两组 32 字节 Base64URL 凭据 + 两个备选地址。
    private var longPayload: String {
        let secret = String(repeating: "a", count: 43)
        let publicKey = String(repeating: "b", count: 43)
        return "wootodo://pair?endpoint=http://stophemo.local:48473"
            + "&pairingId=pairing-lan-0001&pairingSecret=\(secret)"
            + "&initiatorPublicKey=\(publicKey)&vaultId=vault-abcdefghijkl"
            + "&alt=http://10.207.3.40:48473&alt=http://192.168.2.1:48473"
    }

    @Test("二维码按模块整数倍输出，避免缩放丢行")
    func rendersAtIntegerModuleMultiple() throws {
        let rendered = try #require(QRCodeRenderer.render(longPayload))
        #expect(rendered.modules > 40)
        let perModule = Double(rendered.pointSide) / Double(rendered.modules)
        #expect(perModule == perModule.rounded())
        #expect(perModule >= 3)
        // 位图是每模块点数的两倍，Retina 上一像素对一像素。
        #expect(Int(rendered.image.size.width) == Int(rendered.pointSide * 2))
    }

    @Test("更长的配对串仍然生成可用的二维码")
    func rendersLongerPayload() throws {
        let rendered = try #require(QRCodeRenderer.render(longPayload + "&alt=http://172.20.10.2:48473"))
        #expect(rendered.modules >= 45)
        #expect(rendered.pointSide <= 360)
    }
}

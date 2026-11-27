import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import WooTodoSync

enum WebDavInviteJoinError: LocalizedError {
    case missingVault

    var errorDescription: String? {
        switch self {
        case .missingVault:
            "同步空间不存在，可能已被删除或二维码已过期"
        }
    }
}

enum WebDavInviteQRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
    }
}

struct WebDavInviteSheet: View {
    let invite: WebDavInvite
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var encoded: String? { try? invite.encode() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("同步二维码", systemImage: "qrcode")
                    .font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if let encoded, let image = WebDavInviteQRCode.image(for: encoded) {
                HStack(alignment: .top, spacing: 18) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 210, height: 210)
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("同步二维码")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在另一台设备上打开「已有连接设备？扫码同步」，扫描这个二维码，或复制同步信息粘贴过去。")
                            .foregroundStyle(.secondary)
                        Text(encoded)
                            .font(.caption.monospaced())
                            .lineLimit(6)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(copied ? "已复制" : "复制同步信息") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(encoded, forType: .string)
                            copied = true
                        }
                    }
                }
            } else {
                Label("无法生成同步二维码，请重试。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Divider()
            Label(
                "同步二维码包含 WebDAV 应用密码与同步密钥，只给自己的设备扫描或粘贴，不要截图或转发。10 分钟内有效。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            Text("另一台设备连接后会生成自己的设备 ID，并出现在设备列表中。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 640)
    }
}

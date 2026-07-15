import AppKit
import CoreImage
import SwiftUI
import WooTodoSync

struct SyncSettingsView: View {
    @ObservedObject var store: SyncSettingsStore
    @State private var devicePendingRevocation: DeviceInfo?
    @State private var backupPassphrase = ""
    @State private var backupConfirmation = ""

    var body: some View {
        Group {
            if let connection = store.connection {
                configuredContent(connection)
            } else {
                setupContent
            }
        }
        .task {
            if store.connection != nil {
                await store.refreshDevices()
            }
        }
        .confirmationDialog(
            "确认撤销这台设备？",
            isPresented: Binding(
                get: { devicePendingRevocation != nil },
                set: { if !$0 { devicePendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let device = devicePendingRevocation {
                Button("撤销 \(device.name)", role: .destructive) {
                    devicePendingRevocation = nil
                    Task { await store.revokeDevice(device) }
                }
            }
            Button("取消", role: .cancel) {
                devicePendingRevocation = nil
            }
        } message: {
            Text("撤销后，该设备的同步凭据会立即失效；设备上的本地任务不会被远程删除。")
        }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("建立私有同步空间")
                        .font(.title2.weight(.semibold))
                    Text("任务始终先写入本地数据库。同步服务只保存端到端加密后的变更，不需要传统账号。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("同步服务地址")
                        .font(.headline)
                    TextField("https://你的-worker.workers.dev", text: $store.endpointText)
                        .textFieldStyle(.roundedBorder)
                    Text("正式服务必须使用 HTTPS；本地调试仅允许 http://127.0.0.1。请填写服务根地址，不要附加 /v1。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await store.createVault() }
                } label: {
                    if store.isCreatingVault {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("创建同步空间", systemImage: "lock.shield")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isCreatingVault || store.endpointText.isEmpty)

                backupCard
                privacyNote
                actionError
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func configuredContent(_ connection: SyncConnectionSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                connectionCard(connection)
                runtimeCard
                pairingCard
                devicesCard
                backupCard
                privacyNote
                actionError
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func connectionCard(_ connection: SyncConnectionSummary) -> some View {
        SettingsCard(title: "同步连接", systemImage: "lock.shield.fill") {
            LabeledContent("服务地址", value: connection.endpoint.absoluteString)
            LabeledContent("同步空间", value: shortened(connection.vaultId))
            LabeledContent("当前设备", value: shortened(connection.deviceId))
        }
    }

    private var runtimeCard: some View {
        SettingsCard(title: "同步状态", systemImage: "arrow.triangle.2.circlepath") {
            HStack(spacing: 10) {
                statusSymbol
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtimeTitle)
                        .font(.headline)
                    Text(runtimeDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("立即同步") {
                    store.requestSync(.manual)
                }
                .disabled(store.runtimeSnapshot.isRunning)
            }

            if let summary = store.lastRunSummary {
                Divider()
                HStack(spacing: 18) {
                    Label("上传 \(summary.pushed)", systemImage: "arrow.up")
                    Label("下载 \(summary.pulled)", systemImage: "arrow.down")
                    Label("游标 \(summary.finalCursor)", systemImage: "number")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if store.runtimeSnapshot.isRunning {
            ProgressView()
                .controlSize(.small)
        } else if store.runtimeSnapshot.lastErrorMessage != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var runtimeTitle: String {
        if store.runtimeSnapshot.isRunning { return "正在同步" }
        if store.runtimeSnapshot.lastErrorMessage != nil { return "等待下次重试" }
        if store.runtimeSnapshot.lastSuccessfulAt != nil { return "同步正常" }
        return "已连接，等待首次同步"
    }

    private var runtimeDetail: String {
        if let error = store.runtimeSnapshot.lastErrorMessage {
            return error
        }
        if let date = store.runtimeSnapshot.lastSuccessfulAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.unitsStyle = .full
            return "最近成功：\(formatter.localizedString(for: date, relativeTo: Date()))"
        }
        return "网络失败不会阻塞本地任务操作。"
    }

    private var pairingCard: some View {
        SettingsCard(title: "添加 Android 设备", systemImage: "qrcode") {
            pairingContent
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        switch store.pairingPhase {
        case .idle:
            Text("在手机安装 Woo Todo 后，用应用内的配对入口扫描二维码。二维码 10 分钟后自动失效。")
                .foregroundStyle(.secondary)
            Button("生成配对二维码") {
                Task { await store.createPairing() }
            }
            .buttonStyle(.borderedProminent)
        case .creating:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在创建 10 分钟配对会话…")
            }
        case .awaitingClaim(let invitation):
            if let payload = store.pairingQRCodePayload {
                HStack(alignment: .top, spacing: 22) {
                    PairingQRCodeView(payload: payload)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("等待手机扫描")
                            .font(.headline)
                        Text("手机扫描后，两端都会显示同一个六位核对码。")
                            .foregroundStyle(.secondary)
                        Text("有效至 \(formattedMilliseconds(invitation.expiresAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("取消显示", role: .cancel) {
                            store.resetPairing()
                        }
                    }
                }
            }
        case .awaitingVerification(let verification):
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "\(verification.deviceName) 已扫描",
                    systemImage: verification.platform == .android ? "smartphone" : "laptopcomputer"
                )
                Text(verification.code)
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .textSelection(.enabled)
                Text("请确认手机上显示完全相同的六位数字。只有两端一致时才允许传递同步密钥。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("核对一致，确认绑定") {
                        Task { await store.confirmPairing() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("取消", role: .cancel) {
                        store.resetPairing()
                    }
                }
            }
        case .confirming:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在加密传递同步密钥…")
            }
        case .confirmed:
            VStack(alignment: .leading, spacing: 10) {
                Label("设备绑定成功", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("继续添加设备") {
                    store.resetPairing()
                }
            }
        case .expired:
            VStack(alignment: .leading, spacing: 10) {
                Label("二维码已失效", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Button("重新生成") {
                    store.resetPairing()
                    Task { await store.createPairing() }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("重试") {
                    store.resetPairing()
                    Task { await store.createPairing() }
                }
            }
        }
    }

    private var devicesCard: some View {
        SettingsCard(title: "已绑定设备", systemImage: "laptopcomputer.and.iphone") {
            HStack {
                Text("撤销只会使对应设备无法继续同步，不会删除它的本地数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await store.refreshDevices() }
                } label: {
                    if store.isLoadingDevices {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isLoadingDevices)
            }

            if store.devices.isEmpty, !store.isLoadingDevices {
                Text("尚未获取到设备列表。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.devices, id: \.id) { device in
                    Divider()
                    HStack(spacing: 12) {
                        Image(systemName: device.platform == .macos ? "laptopcomputer" : "smartphone")
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(device.name)
                                if isCurrentDevice(device) {
                                    Text("当前设备")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                if device.revokedAt != nil {
                                    Text("已撤销")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(deviceDetail(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !isCurrentDevice(device), device.revokedAt == nil {
                            Button("撤销", role: .destructive) {
                                devicePendingRevocation = device
                            }
                        }
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "vault key 和设备令牌只保存在本机 Keychain，或用户主动导出的加密备份中；服务端无法读取任务明文。",
            systemImage: "key.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var backupCard: some View {
        SettingsCard(title: "加密备份与恢复", systemImage: "externaldrive.badge.lock") {
            Text("备份包含全部任务及当前同步恢复材料，使用 PBKDF2 与 AES-256-GCM 加密。忘记口令后无法解密。")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("备份口令（至少 10 个字符）", text: $backupPassphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("导出时再次输入口令", text: $backupConfirmation)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("导出 .wootodo") {
                    Task {
                        await store.exportBackup(
                            passphrase: backupPassphrase,
                            confirmation: backupConfirmation
                        )
                    }
                }
                .disabled(store.isBackupBusy || backupPassphrase.isEmpty)

                Button("从 .wootodo 恢复") {
                    Task { await store.importBackup(passphrase: backupPassphrase) }
                }
                .disabled(store.isBackupBusy || backupPassphrase.isEmpty || store.connection != nil)

                if store.isBackupBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("恢复仅允许空白安装；新增设备请使用二维码配对。可将导出文件手动上传到夸克网盘。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = store.backupStatusMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var actionError: some View {
        if let message = store.actionErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func shortened(_ value: String) -> String {
        guard value.count > 18 else { return value }
        return "\(value.prefix(8))…\(value.suffix(8))"
    }

    private func formattedMilliseconds(_ value: Int64) -> String {
        Date(timeIntervalSince1970: Double(value) / 1_000)
            .formatted(date: .omitted, time: .shortened)
    }

    private func deviceDetail(_ device: DeviceInfo) -> String {
        let platform = device.platform == .macos ? "macOS" : "Android"
        guard let lastSeenAt = device.lastSeenAt else { return platform }
        let seen = formattedMilliseconds(lastSeenAt)
        return "\(platform) · 最近在线 \(seen)"
    }

    private func isCurrentDevice(_ device: DeviceInfo) -> Bool {
        device.isCurrent || device.id == store.connection?.deviceId
    }

}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct PairingQRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = QRCodeRenderer.render(payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 80))
            }
        }
        .frame(width: 210, height: 210)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("设备配对二维码")
    }
}

private enum QRCodeRenderer {
    static func render(_ payload: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

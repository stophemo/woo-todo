import AppKit
import CoreImage
import SwiftUI
import WooTodoSync

struct SyncSettingsView: View {
    @ObservedObject var store: SyncSettingsStore
    @ObservedObject var webDavStore: WebDavSettingsStore
    @State private var devicePendingRevocation: DeviceInfo?
    @State private var backupPassphrase = ""
    @State private var backupConfirmation = ""
    @State private var includeSyncIdentity = false
    @State private var pairingLinkCopied = false
    @State private var vaultCreationInviteCode = ""

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
                    Text("在线同步")
                        .font(.title2.weight(.semibold))
                    Text("任务始终先写入本地数据库。可直接使用坚果云，或继续使用自建 Worker。")
                        .foregroundStyle(.secondary)
                }

                webDavCard

                VStack(alignment: .leading, spacing: 10) {
                    Text("同步服务地址")
                        .font(.headline)
                    TextField("https://你的-worker.workers.dev", text: $store.endpointText)
                        .textFieldStyle(.roundedBorder)
                    endpointGuidance
                    Text("这里需要填写已部署的 Cloudflare Worker 根地址。Vercel 产品主页和夸克网盘都不是同步服务；夸克网盘仅用于手动保存加密备份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("创建邀请码")
                        .font(.headline)
                    SecureField("部署同步服务时设置的邀请码", text: $vaultCreationInviteCode)
                        .textFieldStyle(.roundedBorder)
                    Text("邀请码须为 16–256 个无空格可打印 ASCII 字符。它仅在首次创建空间时随本次请求发送，不会保存到 UserDefaults、Keychain 或日志。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    let submittedInviteCode = vaultCreationInviteCode
                    Task {
                        await store.createVault(inviteCode: submittedInviteCode)
                        if store.connection != nil {
                            vaultCreationInviteCode = ""
                        }
                    }
                } label: {
                    if store.isCreatingVault {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("创建同步空间", systemImage: "lock.shield")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    store.isCreatingVault
                        || !store.canCreateVault
                        || vaultCreationInviteCode
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                )

                Text("空间创建成功后，Android 无需再输入服务地址；配对二维码会带上同一个地址和一次性配对材料。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                webDavCard
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

    private var webDavCard: some View {
        SettingsCard(title: "坚果云自动同步", systemImage: "externaldrive.connected.to.line.below") {
            LabeledContent("WebDAV 地址", value: WebDavEndpointPolicy.endpoint.absoluteString)
            if webDavStore.workerSyncConfigured {
                Label(
                    "当前任务库已连接 Worker，不能同时启用坚果云同步。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                TextField("坚果云账号邮箱", text: $webDavStore.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("坚果云应用密码", text: $webDavStore.appPassword)
                    .textFieldStyle(.roundedBorder)

                if let connection = webDavStore.connection {
                    LabeledContent("同步空间", value: connection.vaultId)
                    HStack(spacing: 8) {
                        Text("同步密钥")
                        Text(webDavStore.vaultKeyText)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                webDavStore.vaultKeyText,
                                forType: .string
                            )
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("复制同步密钥")
                    }
                    HStack {
                        if webDavStore.runtimeSnapshot.isRunning {
                            ProgressView().controlSize(.small)
                            Text("正在同步")
                        } else if let error = webDavStore.runtimeSnapshot.lastErrorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Label("坚果云已连接", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button("立即同步") { webDavStore.requestSync(.manual) }
                            .disabled(webDavStore.runtimeSnapshot.isRunning)
                    }
                    Button("更新账号或应用密码") {
                        Task { await webDavStore.configure() }
                    }
                    .disabled(webDavStore.isSaving || webDavStore.appPassword.isEmpty)
                } else {
                    TextField("同步空间名（两端完全相同）", text: $webDavStore.vaultId)
                        .textFieldStyle(.roundedBorder)
                    TextField("同步密钥（两端完全相同）", text: $webDavStore.vaultKeyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        Task { await webDavStore.configure() }
                    } label: {
                        if webDavStore.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("保存并连接", systemImage: "link")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        webDavStore.isSaving
                            || webDavStore.username.isEmpty
                            || webDavStore.appPassword.isEmpty
                            || webDavStore.vaultId.isEmpty
                            || webDavStore.vaultKeyText.isEmpty
                    )
                }

                Text("应用密码请在坚果云“账户信息 → 安全选项 → 第三方应用管理”生成；任务标题只以 AES-256-GCM 密文保存，云端仍可见同步所需元数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = webDavStore.actionErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func connectionCard(_ connection: SyncConnectionSummary) -> some View {
        SettingsCard(title: "同步连接", systemImage: "lock.shield.fill") {
            LabeledContent("服务地址", value: connection.endpoint.absoluteString)
            LabeledContent("同步空间", value: shortened(connection.vaultId))
            LabeledContent("当前设备", value: shortened(connection.deviceId))
            if SyncEndpointPolicy.scope(of: connection.endpoint) == .currentDeviceOnly {
                Label(
                    "此连接使用回环地址，只能在当前 Mac 调试，Android 无法加入。127.0.0.1 在手机上代表手机自己。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
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
            Text("Android 不需要创建空间或手动填写服务器地址。按下面步骤加入 Mac 已创建的空间：")
                .foregroundStyle(.secondary)
            androidJoinSteps
            Button("生成配对二维码") {
                pairingLinkCopied = false
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
                        Text("在三星手机下拉快捷面板打开「扫描二维码」（或使用相机），扫描左侧二维码，并选择用 Woo Todo 打开。")
                            .foregroundStyle(.secondary)
                        Text("打开后，两端都会显示同一个六位核对码；暂时不要关闭任一端。")
                            .foregroundStyle(.secondary)
                        Text("有效至 \(formattedMilliseconds(invitation.expiresAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("复制配对链接（备用）") {
                                copyPairingLink(payload)
                            }
                            Button("取消显示", role: .cancel) {
                                store.resetPairing()
                            }
                        }
                        if pairingLinkCopied {
                            Label("已复制。可通过自己的私密渠道发到手机后点击打开。", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Text("配对链接含 10 分钟有效的一次性 secret，请勿发送到群聊或公开位置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                Text("手机会自动执行首次同步。回到 Android 首页，看到“同步完成”后即可在任一端新增测试任务。")
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var endpointGuidance: some View {
        switch store.endpointSetupAssessment {
        case .empty:
            Label("请输入 Mac 与 Android 都能访问的 HTTPS Worker 根地址。", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .invalid:
            Label("地址格式无效；必须以 https:// 开头，且不能包含账号、查询参数或 #片段。", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .currentDeviceOnly:
            Label(
                "127.0.0.1/localhost 只指向当前设备，手机扫码后会连接手机自己，不能用于双端同步。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case .includesAPIVersion:
            Label("请删除末尾的 /v1，只填写 Worker 根地址。", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .ready(let endpoint):
            Label(
                "地址格式正确：\(endpoint.host ?? endpoint.absoluteString)。创建前请确认 Worker 已实际部署。",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        }
    }

    private var androidJoinSteps: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("1. 确认 Mac 与手机均可联网，且上方服务地址是 HTTPS Worker。")
            Text("2. 在 Mac 点击“生成配对二维码”。")
            Text("3. 在三星手机用快捷面板“扫描二维码”扫描，并选择用 Woo Todo 打开。")
            Text("4. 核对两端六位码完全相同，再回到 Mac 点击“确认绑定”。")
            Text("5. 手机保存密钥后会自动首次同步；任务明文不会上传到服务端。")
        }
        .font(.callout)
    }

    private var backupCard: some View {
        SettingsCard(title: "离线接力与加密备份", systemImage: "externaldrive.badge.lock") {
            Text("文件始终端到端加密；忘记口令后无法解密。")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("备份口令（至少 10 个字符）", text: $backupPassphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("导出时再次输入口令", text: $backupConfirmation)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("导出离线接力包") {
                    Task {
                        await store.exportOfflineRelay(
                            passphrase: backupPassphrase,
                            confirmation: backupConfirmation
                        )
                    }
                }
                .disabled(store.isBackupBusy || backupPassphrase.isEmpty)

                Button("合并离线接力包") {
                    Task { await store.mergeOfflineRelay(passphrase: backupPassphrase) }
                }
                .disabled(store.isBackupBusy || backupPassphrase.isEmpty)
            }
            Text("接力包可导入已有任务库，只合并任务和删除记录，不复制同步身份。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("包含当前同步身份（仅用于替换丢失的本机）", isOn: $includeSyncIdentity)
                .disabled(store.connection == nil)
            Text("默认关闭。开启后备份会包含设备令牌与 vault key；旧安装仍在运行时，不要把它恢复成第二份并存设备，新增设备请使用二维码配对。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("导出恢复备份") {
                    Task {
                        await store.exportBackup(
                            passphrase: backupPassphrase,
                            confirmation: backupConfirmation,
                            includeSyncIdentity: includeSyncIdentity
                        )
                    }
                }
                .disabled(store.isBackupBusy || backupPassphrase.isEmpty)

                Button("全新安装恢复") {
                    Task { await store.importBackup(passphrase: backupPassphrase) }
                }
                .disabled(store.isBackupBusy || backupPassphrase.isEmpty || store.connection != nil)

                if store.isBackupBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("恢复备份仅允许空白安装；日常跨设备传递请使用离线接力包。")
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

    private func copyPairingLink(_ payload: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pairingLinkCopied = pasteboard.setString(payload, forType: .string)
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

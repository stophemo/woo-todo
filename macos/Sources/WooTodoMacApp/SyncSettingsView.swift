import AppKit
import CoreImage
import SwiftUI
import WooTodoSync

private enum SyncSwitchTarget {
    case localNetwork
    case webDav
}

struct SyncSettingsView: View {
    @ObservedObject var store: SyncSettingsStore
    @ObservedObject var webDavStore: WebDavSettingsStore
    @State private var devicePendingRevocation: DeviceInfo?
    @State private var pairingLinkCopied = false
    @State private var webDavSetupLinkCopied = false
    @State private var webDavSetupLinkRevealed = false
    @State private var vaultCreationInviteCode = ""
    @State private var syncSwitchTarget: SyncSwitchTarget?

    var body: some View {
        Group {
            if let connection = store.connection {
                configuredContent(connection)
            } else {
                setupContent
            }
        }
        .textSelection(.enabled)
        .task {
            if store.connection != nil {
                await store.refreshDevices()
            }
        }
        .onDisappear {
            webDavSetupLinkRevealed = false
            webDavSetupLinkCopied = false
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
        .confirmationDialog(
            "确认切换同步方式？",
            isPresented: Binding(
                get: { syncSwitchTarget != nil },
                set: { if !$0 { syncSwitchTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch syncSwitchTarget {
            case .localNetwork:
                Button("切换到同一网络同步") {
                    syncSwitchTarget = nil
                    Task { await store.enableLocalNetworkSync(replacingWebDav: true) }
                }
            case .webDav:
                Button("切换到第三方 WebDAV") {
                    syncSwitchTarget = nil
                    Task { await webDavStore.configure(replacingWorkerSync: true) }
                }
            case nil:
                EmptyView()
            }
            Button("取消", role: .cancel) {
                syncSwitchTarget = nil
            }
        } message: {
            Text("本地任务和显示配置会保留并重新同步；旧方式的加密凭据与设备绑定会保留，之后可直接切回。")
        }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("同步方式")
                        .font(.title2.weight(.semibold))
                    Text("任务始终先写入本地数据库。无互联网时可在同一网络同步；联网时可使用第三方 WebDAV 或自建服务。")
                        .foregroundStyle(.secondary)
                }

                localNetworkCard
                webDavCard

                if webDavStore.connection == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("同步服务地址")
                            .font(.headline)
                        TextField("https://你的-worker.workers.dev", text: $store.endpointText)
                            .textFieldStyle(.roundedBorder)
                        endpointGuidance
                        Text("这里需要填写已部署的 Cloudflare Worker 根地址。Vercel 产品主页和夸克网盘都不是同步服务。")
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
                            || webDavStore.isSaving
                            || store.localNetworkHostState == .starting
                            || !store.canCreateVault
                            || vaultCreationInviteCode
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                    )

                    Text("空间创建成功后，Android 无需再输入服务地址；配对二维码会带上同一个地址和一次性配对材料。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                if store.isLocalNetworkConnection {
                    localNetworkCard
                }
                webDavCard
                runtimeCard
                pairingCard
                devicesCard
                privacyNote
                actionError
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var localNetworkCard: some View {
        SettingsCard(title: "同一网络同步", systemImage: "wifi") {
            Text("Mac 作为本地同步主机。手机与 Mac 连接同一网络后扫码配对，无需填写服务地址或同步空间；离开网络仍可编辑，重新连上后自动补齐。")
                .foregroundStyle(.secondary)

            switch store.localNetworkHostState {
            case .disabled:
                if webDavStore.connection != nil {
                    Label("当前正在使用第三方 WebDAV。切换后会保留本地任务，并用新的局域网空间重新同步。", systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button {
                        syncSwitchTarget = .localNetwork
                    } label: {
                        Label("切换到同一网络同步", systemImage: "wifi")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(webDavStore.isSaving || store.isCreatingVault)
                } else if store.connection == nil {
                    Button {
                        Task { await store.enableLocalNetworkSync() }
                    } label: {
                        Label("开启同一网络同步", systemImage: "wifi")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(webDavStore.isSaving || store.isCreatingVault)
                } else {
                    Label("当前任务库正在使用其他同步方式", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .starting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在启动 Mac 局域网同步服务…")
                }
            case .ready(let endpoint):
                Label("局域网同步已开启", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("手机访问地址", value: endpoint.absoluteString)
                Text("地址由应用自动维护，只用于同一网络内连接，无需手动填写。下方可生成 Android 配对二维码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if store.isLocalNetworkConnection {
                    Button {
                        Task { await store.retryLocalNetworkHost() }
                    } label: {
                        Label("重新启动局域网同步", systemImage: "arrow.clockwise")
                    }
                } else if webDavStore.connection == nil {
                    Button {
                        Task { await store.enableLocalNetworkSync() }
                    } label: {
                        Label("重试开启", systemImage: "arrow.clockwise")
                    }
                    .disabled(webDavStore.isSaving || store.isCreatingVault)
                }
            }

            Text("首次开启时 macOS 会询问是否允许访问本地网络；需要选择允许。任务正文仍使用 AES-256-GCM 端到端加密。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var webDavCard: some View {
        SettingsCard(title: "第三方 WebDAV", systemImage: "externaldrive.connected.to.line.below") {
            if store.isCreatingVault
                || store.localNetworkHostState == .starting {
                Label(
                    "另一种同步方式正在配置，请稍候。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                if hasWorkerOrLocalSync {
                    Label(
                        "当前正在使用\(store.isLocalNetworkConnection ? "同一网络" : "自建服务")同步。填写 WebDAV 配置后可以直接切换。",
                        systemImage: "arrow.left.arrow.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                TextField(
                    "https://服务商提供的 WebDAV 根目录",
                    text: $webDavStore.endpointText
                )
                    .textFieldStyle(.roundedBorder)
                Text("填写服务商提供的 WebDAV 根目录，不要填写产品首页或文件浏览网页。为避免认证凭据外送，只接受 HTTPS 地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("WebDAV 账号", text: $webDavStore.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("应用密码或访问令牌", text: $webDavStore.appPassword)
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
                    if let setupLink = webDavStore.setupLinkURL {
                        if webDavSetupLinkRevealed {
                            HStack(alignment: .top, spacing: 16) {
                                QRCodeView(
                                    payload: setupLink.absoluteString,
                                    accessibilityLabel: "WebDAV 配置二维码"
                                )
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("在 Android 扫码加入")
                                        .font(.headline)
                                    Text("二维码和配置链接包含 WebDAV 地址、认证凭据与 Woo Todo 同步密钥，等同完整敏感配置；不含设备身份。Android 打开时请确认目标应用是 Woo Todo。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        copyWebDavSetupLink(setupLink)
                                    } label: {
                                        Label("复制完整配置链接", systemImage: "doc.on.doc")
                                    }
                                    Text("复制会把完整凭据放入剪贴板；使用后请复制其他内容覆盖。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if webDavSetupLinkCopied {
                                        Label("配置链接已复制，请仅通过私密渠道传递。", systemImage: "checkmark.circle")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                    Button("隐藏二维码") {
                                        webDavSetupLinkRevealed = false
                                        webDavSetupLinkCopied = false
                                    }
                                }
                            }
                        } else {
                            Button {
                                webDavSetupLinkRevealed = true
                                webDavSetupLinkCopied = false
                            } label: {
                                Label("显示 Android 配置二维码", systemImage: "qrcode")
                            }
                            Text("二维码含 WebDAV 认证凭据和同步密钥，仅在两台设备旁临时显示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        if webDavStore.runtimeSnapshot.isRunning {
                            ProgressView().controlSize(.small)
                            Text("正在同步")
                        } else if let error = webDavStore.runtimeSnapshot.lastErrorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Label("WebDAV 已连接", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button("立即同步") { webDavStore.requestSync(.manual) }
                            .disabled(webDavStore.runtimeSnapshot.isRunning)
                    }
                    Button("更新服务地址或认证凭据") {
                        webDavSetupLinkRevealed = false
                        webDavSetupLinkCopied = false
                        Task { await webDavStore.configure() }
                    }
                    .disabled(
                        webDavStore.isSaving
                            || webDavStore.endpointText.isEmpty
                            || webDavStore.appPassword.isEmpty
                    )
                } else {
                    TextField("同步空间名（两端完全相同）", text: $webDavStore.vaultId)
                        .textFieldStyle(.roundedBorder)
                    TextField("同步密钥（两端完全相同）", text: $webDavStore.vaultKeyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        if hasWorkerOrLocalSync {
                            syncSwitchTarget = .webDav
                        } else {
                            Task { await webDavStore.configure() }
                        }
                    } label: {
                        if webDavStore.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                hasWorkerOrLocalSync ? "切换到第三方 WebDAV" : "保存并连接",
                                systemImage: hasWorkerOrLocalSync ? "arrow.left.arrow.right" : "link"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        webDavStore.isSaving
                            || webDavStore.endpointText.isEmpty
                            || webDavStore.username.isEmpty
                            || webDavStore.appPassword.isEmpty
                            || webDavStore.vaultId.isEmpty
                            || webDavStore.vaultKeyText.isEmpty
                    )
                }

                Text("请向服务商获取专用 WebDAV HTTPS 根目录和应用密码。Woo Todo 直接连接该目录，只保存 AES-256-GCM 密文；服务地址不能包含账号、查询参数或片段。")
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

    private var hasWorkerOrLocalSync: Bool {
        webDavStore.workerSyncConfigured || store.connection != nil
    }

    private func connectionCard(_ connection: SyncConnectionSummary) -> some View {
        SettingsCard(title: "同步连接", systemImage: "lock.shield.fill") {
            LabeledContent("服务地址", value: connection.endpoint.absoluteString)
            if !store.isLocalNetworkConnection {
                LabeledContent("同步空间", value: shortened(connection.vaultId))
            }
            LabeledContent("当前设备", value: shortened(connection.deviceId))
            if SyncEndpointPolicy.scope(of: connection.endpoint) == .currentDeviceOnly {
                Label(
                    "此连接使用回环地址，只能在当前 Mac 调试，Android 无法加入。127.0.0.1 在手机上代表手机自己。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if store.isLocalNetworkConnection {
                Label("同一网络同步 · Mac 作为主机", systemImage: "wifi")
                    .foregroundStyle(.green)
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
            Text("Android 不需要创建空间或手动填写服务器地址。按下面步骤加入当前同步：")
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
                    QRCodeView(payload: payload, accessibilityLabel: "设备配对二维码")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("等待手机扫描")
                            .font(.headline)
                        Text("在 Android 设备上使用系统相机、二维码扫描入口或 Woo Todo 内置扫码，扫描左侧二维码并用 Woo Todo 打开。")
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
            "vault key 和设备令牌只保存在本机 Keychain；服务端无法读取任务明文。",
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
            if store.isLocalNetworkConnection {
                Text("1. 确认 Mac 与手机连接同一个 Wi-Fi 或有线局域网。")
            } else {
                Text("1. 确认 Mac 与手机均可联网，且上方服务地址是 HTTPS Worker。")
            }
            Text("2. 在 Mac 点击“生成配对二维码”。")
            Text("3. 在 Android 设备上使用系统相机、二维码扫描入口或 Woo Todo 内置扫码，并用 Woo Todo 打开。")
            Text("4. 核对两端六位码完全相同，再回到 Mac 点击“确认绑定”。")
            Text("5. 手机保存密钥后会自动首次同步；任务明文不会上传到服务端。")
        }
        .font(.callout)
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

    private func copyWebDavSetupLink(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        webDavSetupLinkCopied = pasteboard.setString(url.absoluteString, forType: .string)
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

private struct QRCodeView: View {
    let payload: String
    let accessibilityLabel: String

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
        .frame(width: 260, height: 260)
        .padding(8)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(accessibilityLabel)
    }
}

private enum QRCodeRenderer {
    private static let quietZoneModules: CGFloat = 4

    static func render(_ payload: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let paddedExtent = CGRect(
            x: 0,
            y: 0,
            width: extent.width + quietZoneModules * 2,
            height: extent.height + quietZoneModules * 2
        )
        let positioned = output.transformed(
            by: CGAffineTransform(
                translationX: quietZoneModules - extent.minX,
                y: quietZoneModules - extent.minY
            )
        )
        let whiteBackground = CIImage(
            color: CIColor(red: 1, green: 1, blue: 1)
        ).cropped(to: paddedExtent)
        let padded = positioned.composited(over: whiteBackground)
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

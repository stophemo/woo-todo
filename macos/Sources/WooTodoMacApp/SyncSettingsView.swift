import AppKit
import SwiftUI
import WooTodoSync

private enum WebDavProviderExample: String, CaseIterable, Identifiable {
    case jianguoyun
    case nextcloud
    case synology
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .jianguoyun: "坚果云"
        case .nextcloud: "Nextcloud"
        case .synology: "群晖 Synology"
        case .custom: "自定义"
        }
    }

    var endpoint: String {
        switch self {
        case .jianguoyun: "https://dav.jianguoyun.com/dav/"
        case .nextcloud: "https://你的域名/remote.php/dav/files/用户名/"
        case .synology: "https://你的域名:5006/"
        case .custom: ""
        }
    }

    var hint: String {
        switch self {
        case .jianguoyun: "在坚果云「账户信息 → 安全选项」中添加应用密码，用户名填写登录邮箱。"
        case .nextcloud: "使用「WebDAV 地址」并在设置中创建应用密码；地址通常含 /remote.php/dav/files/用户名/。"
        case .synology: "在群晖「控制面板 → 文件服务 → WebDAV」启用 HTTPS，端口通常为 5006。"
        case .custom: "填写供应商提供的 WebDAV 根目录，必须使用 HTTPS。"
        }
    }
}

struct SyncSettingsView: View {
    @ObservedObject var store: SyncSettingsStore
    @State private var claimCodeInput = ""
    @State private var joinCodeInput = ""
    @State private var showsExitConfirmation = false

    var body: some View {
        Group {
            if store.connection != nil {
                configuredContent
            } else if store.account != nil {
                unpairedContent
            } else {
                accountSetupContent
            }
        }
        .textSelection(.enabled)
        .confirmationDialog(
            "退出此同步空间？",
            isPresented: $showsExitConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出同步空间", role: .destructive) {
                Task { await store.exitSpace() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本机同步身份并停止同步；WebDAV 账号与本地任务会保留，其他设备不受影响。WebDAV 没有服务端设备列表，如需阻止旧设备同步，请在供应商处修改应用密码。")
        }
    }

    // MARK: - 首次配置账号

    private var accountSetupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    "跨设备",
                    "任务在设备间端到端加密同步。每台设备先配置同一个 WebDAV 账号，之后新增设备只需要六位配对码；配对码 5 分钟内有效。"
                )
                if let notice = store.legacyNotice {
                    legacyNotice(notice)
                }
                accountCard
                privacyNote
                feedback
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var accountCard: some View {
        SettingsCard(title: "WebDAV 账号", systemImage: "externaldrive.connected.to.line.below") {
            VStack(alignment: .leading, spacing: 12) {
                Text("WebDAV 供应商由你选择。所有设备配置同一个账号与目录，Woo Todo 只在该目录保存端到端加密密文。")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("https://dav.jianguoyun.com/dav/", text: $store.endpointText)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(WebDavProviderExample.allCases) { provider in
                            Button(provider.title) {
                                if provider != .custom {
                                    store.endpointText = provider.endpoint
                                }
                            }
                        }
                    } label: {
                        Label("供应商示例", systemImage: "questionmark.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                endpointGuidance
                TextField("WebDAV 用户名", text: $store.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("应用密码或访问令牌", text: $store.appPassword)
                    .textFieldStyle(.roundedBorder)
                Text("建议使用供应商提供的应用专用密码，而不是登录密码。地址必须使用 HTTPS，可以包含供应商要求的路径，但不能包含账号、查询参数或片段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        Task { await store.testAndSaveAccount() }
                    } label: {
                        if store.isSavingAccount {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("测试连接并保存", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSavingAccount || !store.canSaveAccount)
                    Text("保存前会创建并读取 v1/pairing 目录，确认地址与权限可用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var endpointGuidance: some View {
        switch store.endpointAssessment {
        case .empty:
            Label("请输入供应商提供的 HTTPS WebDAV 根目录。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .invalid:
            Label(
                "地址格式无效：必须使用 https://，不能包含账号、查询参数或 #片段。",
                systemImage: "xmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
        case .ready(let endpoint):
            Label(
                "地址格式正确：\(endpoint.host ?? endpoint.absoluteString)。请确认路径是 WebDAV 根目录。",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        }
    }

    // MARK: - 已配置账号、未加入空间

    private var unpairedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    "跨设备",
                    "WebDAV 账号已配置。第一台设备建立同步空间，其他设备用六位配对码加入；配对码 5 分钟内有效。"
                )
                if let notice = store.legacyNotice {
                    legacyNotice(notice)
                }
                accountSummaryCard
                createSpaceCard
                pathAClaimCard
                pathBCreateCard
                privacyNote
                feedback
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var accountSummaryCard: some View {
        SettingsCard(title: "WebDAV 账号", systemImage: "checkmark.shield.fill") {
            if let account = store.account {
                LabeledContent("地址", value: account.endpoint.absoluteString)
                LabeledContent("用户名", value: account.username)
                Text("账号与应用密码保存在本机加密文件中；WebDAV 供应商只能看到端到端加密密文与配对所需的公开信息（公钥、设备名、配对码）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var createSpaceCard: some View {
        SettingsCard(title: "建立同步空间", systemImage: "lock.shield") {
            Text("第一台设备建立新空间，生成随机同步密钥。之后所有设备都可以用六位配对码加入，不需要再输入空间 ID 或密钥。")
                .foregroundStyle(.secondary)
            Button {
                Task { await store.createVault() }
            } label: {
                if store.isCreatingVault {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("建立同步空间", systemImage: "lock.shield")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isCreatingVault)
        }
    }

    private var pathAClaimCard: some View {
        SettingsCard(title: "输入配对码加入", systemImage: "rectangle.and.pencil.and.ellipsis") {
            switch store.pathAClaimPhase {
            case .idle:
                VStack(spacing: 14) {
                    Text("在另一台已同步设备上选择「显示配对码」，然后输入它显示的六位数字。")
                        .foregroundStyle(.secondary)
                    SixDigitCodeField(code: $claimCodeInput) {
                        submitClaimCode()
                    }
                    HStack(spacing: 12) {
                        Button {
                            paste(into: $claimCodeInput)
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        Button("配对") {
                            submitClaimCode()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(claimCodeInput.count != 6)
                    }
                    Text("配对码 5 分钟内有效，两端还需核对另外显示的六位核对码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            case .claiming:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取配对文件并认领设备…")
                }
            case let .awaitingApproval(code, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label("已找到配对请求", systemImage: "laptopcomputer.and.iphone")
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: code)
                    Text("请与另一台设备核对六位核对码完全一致。对方批准后，本机还会要求你再次确认才会加入。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    Button("取消", role: .cancel) {
                        store.cancelShortCodeClaim()
                    }
                }
            case let .awaitingConfirmation(deviceName, platform, verificationCode, vaultId, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "\(deviceName) · \(platformName(platform)) 已批准加入",
                        systemImage: platform == .android ? "smartphone" : "laptopcomputer"
                    )
                    Text("空间 ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(shortened(vaultId))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: verificationCode)
                    Text("请与另一台设备核对六位核对码与空间 ID 完全一致；只有一致时才点击下方按钮加入。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    HStack {
                        Button("核对一致，完成加入") {
                            Task { await store.confirmShortCodeClaim() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("取消", role: .cancel) {
                            store.cancelShortCodeClaim()
                        }
                    }
                }
            case .confirmed:
                Label("已通过配对码加入同步空间", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("重试") {
                        store.cancelShortCodeClaim()
                    }
                }
            }
        }
    }

    private var pathBCreateCard: some View {
        SettingsCard(title: "显示我的配对码", systemImage: "number.square") {
            switch store.pathBCreatePhase {
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机显示六位配对码，在另一台已同步设备上选择「输入新设备配对码」并批准。")
                        .foregroundStyle(.secondary)
                    Button("生成配对码") {
                        Task { await store.createJoinRequest() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .creating:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在创建 5 分钟配对码…")
                }
            case let .waiting(code, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Text("六位配对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: code)
                    Text("在另一台已同步设备上输入这 6 位数字。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    Button("取消", role: .cancel) {
                        Task { await store.cancelJoinCreation() }
                    }
                }
            case let .awaitingApproval(verificationCode, deviceName, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(deviceName) 已读取配对码", systemImage: "laptopcomputer.and.iphone")
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: verificationCode)
                    Text("请与另一台设备核对六位核对码完全一致。对方批准后，本机还会要求你再次确认才会加入。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    Button("取消", role: .cancel) {
                        Task { await store.cancelJoinCreation() }
                    }
                }
            case let .awaitingConfirmation(verificationCode, deviceName, vaultId, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(deviceName) 已批准加入", systemImage: "laptopcomputer.and.iphone")
                    Text("空间 ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(shortened(vaultId))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: verificationCode)
                    Text("请与另一台设备核对六位核对码与空间 ID 完全一致；只有一致时才点击下方按钮加入。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    HStack {
                        Button("核对一致，完成加入") {
                            Task { await store.confirmJoinCreation() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("取消", role: .cancel) {
                            Task { await store.cancelJoinCreation() }
                        }
                    }
                }
            case .approved:
                Label("已加入同步空间", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .expired:
                VStack(alignment: .leading, spacing: 10) {
                    Label("配对码已失效", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("重新生成") {
                        store.resetJoinCreation()
                        Task { await store.createJoinRequest() }
                    }
                }
            case .canceled:
                VStack(alignment: .leading, spacing: 10) {
                    Text("配对已取消。")
                        .foregroundStyle(.secondary)
                    Button("重新生成") {
                        store.resetJoinCreation()
                        Task { await store.createJoinRequest() }
                    }
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("重试") {
                        store.resetJoinCreation()
                        Task { await store.createJoinRequest() }
                    }
                }
            }
        }
    }

    // MARK: - 已加入空间

    private var configuredContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    "跨设备",
                    "任务通过 WebDAV 端到端加密同步。添加设备时两端会显示同一个六位核对码，核对一致后再批准；配对码 5 分钟内有效。"
                )
                spaceCard
                pathAShowCard
                pathBApproveCard
                privacyNote
                feedback
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var spaceCard: some View {
        SettingsCard(title: "同步空间", systemImage: "lock.shield.fill") {
            if let connection = store.connection {
                LabeledContent("空间", value: shortened(connection.vaultId))
                LabeledContent("当前设备", value: connection.deviceName)
                LabeledContent("WebDAV", value: connection.endpoint.absoluteString)
            }
            HStack(spacing: 10) {
                statusSymbol
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtimeTitle)
                        .font(.headline)
                    Text(runtimeDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = store.lastRunSummary {
                Divider()
                HStack(spacing: 18) {
                    Label("上传 \(summary.pushed)", systemImage: "arrow.up")
                    Label("下载 \(summary.pulled)", systemImage: "arrow.down")
                    Label("批次 \(summary.pages)", systemImage: "number")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    store.requestSync(.manual)
                } label: {
                    if store.runtimeSnapshot.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("立即同步", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.runtimeSnapshot.isRunning)
                Spacer()
                Button("退出此同步空间", role: .destructive) {
                    showsExitConfirmation = true
                }
                .disabled(store.isExitingSpace)
            }
            Divider()
            Label(
                "WebDAV 没有服务端设备列表，无法远程移除已配对设备。如需阻止旧设备继续同步，请在 WebDAV 供应商处修改应用密码。",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusSymbol: some View {
        Group {
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

    private var pathAShowCard: some View {
        SettingsCard(title: "显示配对码（等待新设备）", systemImage: "number.square") {
            switch store.pathAShowPhase {
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机显示六位配对码；在新设备上选择「输入配对码加入」，两端核对六位核对码一致后由本机确认绑定。")
                        .foregroundStyle(.secondary)
                    Button("显示配对码") {
                        Task { await store.createPairing() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .creating:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在生成 5 分钟配对码…")
                }
            case let .awaitingClaim(code, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Text("六位配对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: code)
                    Text("等待新设备输入配对码。接入后两端都会显示同一个六位核对码。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    Button("取消显示", role: .cancel) {
                        store.resetPairing()
                    }
                }
            case let .awaitingVerification(deviceName, platform, code, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "\(deviceName) 已输入配对码",
                        systemImage: platform == .android ? "smartphone" : "laptopcomputer"
                    )
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: code)
                    Text("请核对两端显示的六位核对码完全一致。只有一致时才允许传递同步密钥。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
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
            case .confirmed:
                VStack(alignment: .leading, spacing: 10) {
                    Label("设备绑定成功", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("新设备会自动执行首次同步。")
                        .foregroundStyle(.secondary)
                    Button("继续添加设备") {
                        store.resetPairing()
                    }
                }
            case .expired:
                VStack(alignment: .leading, spacing: 10) {
                    Label("配对码已失效", systemImage: "clock.badge.exclamationmark")
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
    }

    private var pathBApproveCard: some View {
        SettingsCard(title: "输入新设备配对码", systemImage: "rectangle.and.pencil.and.ellipsis") {
            switch store.pathBApprovePhase {
            case .idle:
                VStack(spacing: 14) {
                    Text("在新设备上选择「显示我的配对码」，然后输入它显示的六位数字。")
                        .foregroundStyle(.secondary)
                    SixDigitCodeField(code: $joinCodeInput) {
                        submitJoinCode()
                    }
                    HStack(spacing: 12) {
                        Button {
                            paste(into: $joinCodeInput)
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        Button("核对") {
                            submitJoinCode()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(joinCodeInput.count != 6)
                    }
                    Text("配对码 5 分钟内有效，使用一次后失效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            case .resolving:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在解析新设备配对码…")
                }
            case let .awaitingConfirmation(deviceName, platform, code, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "\(deviceName) · \(platformName(platform))",
                        systemImage: platform == .android ? "smartphone" : "laptopcomputer"
                    )
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: code)
                    Text("请与新设备核对六位核对码完全一致，再批准加入。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    HStack {
                        Button("核对一致，批准加入") {
                            Task { await store.approveJoin() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("取消", role: .cancel) {
                            store.cancelJoinApproval()
                        }
                    }
                }
            case .approving:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在加密传递同步密钥…")
                }
            case .done:
                VStack(alignment: .leading, spacing: 10) {
                    Label("已批准新设备加入", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("新设备会自动执行首次同步。")
                        .foregroundStyle(.secondary)
                    Button("继续") {
                        store.resetJoinApprover()
                    }
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("重试") {
                        store.resetJoinApprover()
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "WebDAV 供应商只能看到端到端加密的任务密文、配对公钥、设备名与配对码；无法解密任务或同步密钥。",
                systemImage: "key.fill"
            )
            Label(
                "备份文件不包含 WebDAV 账号与同步身份。在新设备恢复备份后，需要重新配置 WebDAV 账号并重新配对才能继续同步。",
                systemImage: "externaldrive.badge.xmark"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legacyNotice(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(notice)
                Button("知道了") {
                    store.acknowledgeLegacyNotice()
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private var feedback: some View {
        if let message = store.statusMessage {
            Label(message, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }
        if let message = store.actionErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func pageHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private func expiryText(_ deadline: Date) -> some View {
        Text("有效至 \(deadline.formatted(date: .omitted, time: .shortened))（5 分钟内有效）")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func shortened(_ value: String) -> String {
        guard value.count > 18 else { return value }
        return "\(value.prefix(8))…\(value.suffix(8))"
    }

    private func platformName(_ platform: DevicePlatform) -> String {
        switch platform {
        case .macos: "macOS"
        case .android: "Android"
        case .windows: "Windows"
        }
    }

    private func submitClaimCode() {
        let code = claimCodeInput.filter(\.isNumber)
        guard code.count == 6 else { return }
        store.claimByShortCode(code)
    }

    private func submitJoinCode() {
        let code = joinCodeInput.filter(\.isNumber)
        guard code.count == 6 else { return }
        Task { await store.resolveJoinCode(code) }
    }

    private func paste(into binding: Binding<String>) {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        let digits = String(value.filter(\.isNumber).prefix(6))
        if !digits.isEmpty {
            binding.wrappedValue = digits
        }
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

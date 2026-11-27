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
        case .jianguoyun: "请使用坚果云「账户信息 → 安全选项」中的第三方应用密码，用户名填写登录邮箱。"
        case .nextcloud: "使用「WebDAV 地址」并在设置中创建应用密码；地址通常含 /remote.php/dav/files/用户名/。"
        case .synology: "在群晖「控制面板 → 文件服务 → WebDAV」启用 HTTPS，端口通常为 5006。"
        case .custom: "填写供应商提供的 WebDAV 根目录，必须使用 HTTPS。"
        }
    }

    static func matching(_ endpoint: String) -> Self {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("https://dav.jianguoyun.com/") { return .jianguoyun }
        if value.contains("/remote.php/dav/") { return .nextcloud }
        if value.contains(":5006") { return .synology }
        return .custom
    }
}

struct SyncSettingsView: View {
    @ObservedObject var store: SyncSettingsStore
    @State private var claimCodeInput = ""
    @State private var joinCodeInput = ""
    @State private var showsExitConfirmation = false
    @State private var isEditingAccount = false
    @State private var selectedProvider: WebDavProviderExample = .jianguoyun
    @State private var inviteInput = ""
    @State private var presentedInvite: WebDavInvite?

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
        .onAppear(perform: syncProviderSelection)
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
            Text("只删除本机同步身份并停止同步；WebDAV 账号与本地任务会保留，其他设备不受影响。")
        }
        .alert(
            joinPolicyTitle,
            isPresented: Binding(
                get: { store.joinPolicyPrompt != nil },
                set: { _ in }
            ),
            presenting: store.joinPolicyPrompt
        ) { prompt in
            switch prompt {
            case .clearLocalData:
                Button("继续加入（清空本机数据）") {
                    Task { await store.continueJoinClearingLocalTasks() }
                }
                Button("取消", role: .cancel) {
                    store.cancelJoinPolicyPrompt()
                }
            case .chooseSpace:
                Button("以对方为准（清空本机任务和身份后加入）", role: .destructive) {
                    Task { await store.joinUsingPeerData() }
                }
                Button("以本机为准（请在对方设备输入本机配对码）") {
                    store.joinUsingLocalData()
                }
                Button("取消", role: .cancel) {
                    store.cancelJoinPolicyPrompt()
                }
            }
        } message: { prompt in
            Text(joinPolicyMessage(prompt))
        }
        .alert(
            "连接同步空间",
            isPresented: Binding(
                get: { store.inviteJoinPrompt != nil },
                set: { _ in }
            ),
            presenting: store.inviteJoinPrompt
        ) { prompt in
            if prompt.needsClear {
                Button("清空本机数据并加入", role: .destructive) {
                    Task { await store.confirmInviteJoin() }
                }
            } else {
                Button("加入同步空间") {
                    Task { await store.confirmInviteJoin() }
                }
            }
            Button("取消", role: .cancel) {
                store.cancelInviteJoin()
            }
        } message: { prompt in
            Text(inviteJoinMessage(prompt))
        }
        .sheet(item: $presentedInvite) { invite in
            WebDavInviteSheet(invite: invite)
        }
    }

    // MARK: - 首次配置账号

    private var accountSetupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    "跨设备",
                    "填写你的 WebDAV 账号。任务在本机加密后上传。"
                )
                if let notice = store.legacyNotice {
                    legacyNotice(notice)
                }
                accountCard
                syncJoinCard
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
                accountFields
                HStack(spacing: 12) {
                    Button {
                        Task { await store.testAndSaveAccount() }
                    } label: {
                        if store.isSavingAccount {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("检查连接", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSavingAccount || !store.canSaveAccount)
                }
            }
        }
    }

    /// 用户只需要填：服务商、地址（默认带出）、账户、应用密码。
    private var accountFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("服务商") {
                Picker("服务商", selection: $selectedProvider) {
                    ForEach(WebDavProviderExample.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .trailing)
                .onChange(of: selectedProvider) { _, provider in
                    if provider != .custom {
                        store.endpointText = provider.endpoint
                    }
                }
            }
            TextField("https://dav.jianguoyun.com/dav/", text: $store.endpointText)
                .textFieldStyle(.roundedBorder)
            endpointGuidance
            TextField("WebDAV 账户（登录邮箱或用户名）", text: $store.username)
                .textFieldStyle(.roundedBorder)
            SecureField("应用密码（不是登录密码）", text: $store.appPassword)
                .textFieldStyle(.roundedBorder)
            Text(selectedProvider.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("同步文件只写入该地址下的 WooTodo 专属文件夹，不会和其他应用混在一起。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func syncProviderSelection() {
        if store.endpointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedProvider = .jianguoyun
            store.endpointText = selectedProvider.endpoint
        } else {
            selectedProvider = WebDavProviderExample.matching(store.endpointText)
        }
    }

    @ViewBuilder
    private var endpointGuidance: some View {
        switch store.endpointAssessment {
        case .empty:
            Label("请输入供应商提供的 HTTPS WebDAV 根目录；新账号会自动使用 WooTodo 专属文件夹。", systemImage: "info.circle")
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
                    "连接后即可同步。"
                )
                if let notice = store.legacyNotice {
                    legacyNotice(notice)
                }
                createSpaceCard
                syncJoinCard
                if isEditingAccount {
                    accountEditorCard
                } else {
                    Button("更换账号") {
                        beginAccountEditing()
                    }
                    .buttonStyle(.link)
                }
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
                LabeledContent("地址") {
                    Text(account.endpoint.absoluteString)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(account.endpoint.absoluteString)
                        .textSelection(.enabled)
                }
                LabeledContent("服务商", value: WebDavProviderExample.matching(
                    account.endpoint.absoluteString
                ).title)
                LabeledContent("用户名", value: account.username)
                Button {
                    beginAccountEditing()
                } label: {
                    Label("编辑账号", systemImage: "pencil")
                }
                .disabled(store.isSavingAccount)
            }
        }
    }

    private var accountEditorCard: some View {
        SettingsCard(title: "编辑 WebDAV 账号", systemImage: "pencil") {
            VStack(alignment: .leading, spacing: 12) {
                accountFields
                Text("保存不会退出当前同步空间，配对身份、本地任务与设备列表保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = store.actionErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let message = store.statusMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                HStack(spacing: 12) {
                    Button {
                        Task { await store.testAndSaveAccount() }
                    } label: {
                        if store.isSavingAccount {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("检查连接", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSavingAccount || !store.canSaveAccount)
                    Button("收起表单") {
                        isEditingAccount = false
                    }
                }
            }
        }
    }

    private var createSpaceCard: some View {
        SettingsCard(title: "同步", systemImage: "lock.shield") {
            Text("尚未同步")
                .font(.headline)
            Text("上次同步：—")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("在这台设备生成同步密钥。之后让其他设备打开「已有连接设备？扫码同步」。")
                .foregroundStyle(.secondary)
            Button {
                Task { await store.createVault() }
            } label: {
                if store.isCreatingVault {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("开始同步", systemImage: "lock.shield")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isCreatingVault)
        }
    }

    private var pathAClaimCard: some View {
        SettingsCard(
            title: store.identity == nil ? "输入配对码加入" : "输入配对码加入其他空间",
            systemImage: "rectangle.and.pencil.and.ellipsis"
        ) {
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
            case .awaitingDecision:
                Text("请在弹出的提示中选择以哪台设备的数据为准。")
                    .foregroundStyle(.secondary)
            case let .awaitingApproval(code, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label("已找到配对请求", systemImage: "laptopcomputer.and.iphone")
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: code)
                    Text("请与另一台设备核对六位核对码完全一致。对方批准后会自动加入并同步，不需要在本机再次确认。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    Button("取消", role: .cancel) {
                        store.cancelShortCodeClaim()
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
            case .awaitingDecision:
                Text("请在弹出的提示中选择以哪台设备的数据为准。")
                    .foregroundStyle(.secondary)
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
                    Text("请与另一台设备核对六位核对码完全一致。对方批准后会自动加入并同步，不需要在本机再次确认。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    Button("取消", role: .cancel) {
                        Task { await store.cancelJoinCreation() }
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
                    "任务通过 WebDAV 端到端加密同步。"
                )
                spaceCard
                deviceCard
                Button("退出同步", role: .destructive) {
                    showsExitConfirmation = true
                }
                .buttonStyle(.link)
                .disabled(store.isExitingSpace)
                feedback
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var spaceCard: some View {
        SettingsCard(title: "同步", systemImage: "lock.shield.fill") {
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
                Button {
                    presentedInvite = store.makeInvite()
                } label: {
                    Label("同步二维码", systemImage: "qrcode")
                }
            }
        }
    }

    private var deviceCard: some View {
        SettingsCard(title: "设备", systemImage: "laptopcomputer.and.iphone") {
            if store.isRefreshingDevices && store.devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取设备列表…")
                        .foregroundStyle(.secondary)
                }
            } else if store.devices.isEmpty {
                Text("还没有其他设备同步过")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.devices) { device in
                        deviceRow(device)
                    }
                    if store.devices.allSatisfy({ $0.isCurrent }) {
                        Text("还没有其他设备同步过")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let message = store.devicesErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await store.refreshDevices() }
            } label: {
                if store.isRefreshingDevices {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("刷新设备列表", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshingDevices)
            Text("设备列表来自加密心跳，可能不是最新状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await store.refreshDevices() }
    }

    private func deviceRow(_ device: SyncDeviceSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: device.platform == .android ? "smartphone" : "laptopcomputer")
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(device.name)
                    if device.isCurrent {
                        Text("本机")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .fixedSize()
                    }
                    if isStale(device.lastSeenAt) {
                        Text("很久未同步")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize()
                    }
                }
                Text(
                    "\(platformName(device.platform)) · v\(device.appVersion) · \(lastSeenDescription(device.lastSeenAt))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func lastSeenDescription(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return "最近同步：\(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func isStale(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) > 30 * 24 * 60 * 60
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
        return "上次同步：—"
    }

    private var syncJoinCard: some View {
        SettingsCard(title: "已有连接设备？", systemImage: "qrcode.viewfinder") {
            VStack(alignment: .leading, spacing: 10) {
                Text("粘贴另一台设备「同步二维码」里的信息即可连接。")
                    .foregroundStyle(.secondary)
                TextField("粘贴同步信息…", text: $inviteInput, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                HStack(spacing: 12) {
                    Button {
                        Task { await store.prepareInviteJoin(inviteInput) }
                    } label: {
                        if store.isJoiningWithInvite {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("连接", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        store.isJoiningWithInvite
                            || inviteInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                    )
                    Button("从剪贴板粘贴") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            inviteInput = text
                        }
                    }
                }
                Text("同步信息里已包含地址、账号和密钥，不需要再填写账号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inviteJoinMessage(_ prompt: WebDavInviteJoinPrompt) -> String {
        var lines = [
            "将连接同步空间 \(shortened(prompt.invite.vaultId))，并使用对方设备的数据。",
        ]
        if prompt.changesAccount {
            lines.append(
                "本机会改用同步信息里的 WebDAV 账号（\(prompt.invite.account.username)）。"
            )
        }
        if prompt.needsClear {
            if let summary = prompt.localSummary, summary.hasAnyData {
                lines.append(
                    "本机现有 \(summary.taskCount) 个任务、\(summary.trashCount) 个回收站条目、\(summary.customCategoryCount) 个自定义分类。"
                )
            } else if store.identity != nil {
                lines.append("本机已连接另一个同步空间。")
            }
            lines.append("继续后会先清空本机任务、回收站、分类和旧同步身份。")
        }
        lines.append("如果同步信息不是来自你自己的设备，请取消。")
        return lines.joined(separator: "\n")
    }

    private var pathAShowCard: some View {
        SettingsCard(title: "显示配对码（等待新设备）", systemImage: "number.square") {
            switch store.pathAShowPhase {
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机显示六位配对码；在新设备上选择「输入配对码加入」，两端核对六位核对码一致后由本机批准。")
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
                        "\(deviceName) · \(platformName(platform)) 请求加入",
                        systemImage: platform == .android ? "smartphone" : "laptopcomputer"
                    )
                    Text("六位核对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: code)
                    Text("请核对两端显示的六位核对码完全一致。如果这不是你正在操作的设备，请不要批准。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    HStack {
                        Button("批准加入") {
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
                    Label("已批准设备加入", systemImage: "checkmark.circle.fill")
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
                    Text("请与新设备核对六位核对码完全一致。如果这不是你正在操作的设备，请不要批准。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    HStack {
                        Button("批准加入") {
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
                "WebDAV 无法远程吊销设备；要阻止旧设备继续同步，请修改应用密码。",
                systemImage: "exclamationmark.triangle"
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
        if !isEditingAccount, let message = store.statusMessage {
            Label(message, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }
        if !isEditingAccount, let message = store.actionErrorMessage {
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

    private func sectionHeader(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
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

    private var joinPolicyTitle: String {
        guard let prompt = store.joinPolicyPrompt else { return "加入同步空间" }
        switch prompt {
        case .clearLocalData:
            return "本机数据将被清空"
        case .chooseSpace:
            return "选择以哪台设备的数据为准"
        }
    }

    private func joinPolicyMessage(_ prompt: JoinPolicyPrompt) -> String {
        switch prompt {
        case .clearLocalData(let summary):
            return "本机有 \(summary.summaryDescription)。加入后将以对方设备的数据为准，本机任务、回收站与标签会被清空；WebDAV 账号与显示偏好会保留。"
        case let .chooseSpace(
            localVaultId,
            lastSyncedAt,
            peerDeviceName,
            peerPlatform
        ):
            let lastSync = lastSyncedAt.map { date in
                let formatter = RelativeDateTimeFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.unitsStyle = .full
                return formatter.localizedString(for: date, relativeTo: Date())
            } ?? "尚未成功同步"
            return "本机已有同步空间 \(shortened(localVaultId))（最近同步：\(lastSync)）；对方设备：\(peerDeviceName) · \(platformName(peerPlatform))。\n\n以对方为准会清空本机任务、回收站与同步身份，保留 WebDAV 账号与显示偏好；以本机为准会取消本次输入，请在本机显示配对码后到对方设备输入。"
        }
    }

    private func beginAccountEditing() {
        if let account = store.account {
            store.endpointText = account.endpoint.absoluteString
            store.username = account.username
            store.appPassword = account.appPassword
        }
        selectedProvider = WebDavProviderExample.matching(store.endpointText)
        isEditingAccount = true
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

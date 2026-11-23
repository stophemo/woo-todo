import AppKit
import SwiftUI
import WooTodoSync

struct SyncSettingsView: View {
    @ObservedObject var store: SyncSettingsStore
    @State private var claimCodeInput = ""
    @State private var joinCodeInput = ""
    @State private var vaultCreationInviteCode = ""
    @State private var devicePendingRemoval: DeviceInfo?
    @State private var showsExitConfirmation = false

    var body: some View {
        Group {
            if let connection = store.connection {
                configuredContent(connection)
            } else {
                unpairedContent
            }
        }
        .textSelection(.enabled)
        .task {
            if store.connection != nil {
                await store.refreshDevices()
            }
        }
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
            Text("本机会删除同步凭据并停止同步，本地任务会保留；其他设备不受影响。")
        }
        .confirmationDialog(
            devicePendingRemoval.map { "移除「\($0.name)」？" } ?? "移除设备？",
            isPresented: Binding(
                get: { devicePendingRemoval != nil },
                set: { if !$0 { devicePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除设备", role: .destructive) {
                guard let device = devicePendingRemoval else { return }
                devicePendingRemoval = nil
                Task { await store.removeDevice(device) }
            }
            Button("取消", role: .cancel) {
                devicePendingRemoval = nil
            }
        } message: {
            Text("该设备将停止同步，不会再收到后续变更；设备上的本地任务不会被删除。")
        }
    }

    // MARK: - 未配对

    private var unpairedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    "跨设备",
                    "任务在设备间端到端加密同步。已有空间只需输入另一台设备的六位配对码；建立新空间需要部署者邀请码。配对码 5 分钟内有效。"
                )

                if let notice = store.legacyNotice {
                    legacyNotice(notice)
                }

                serverCard
                claimCodeCard
                joinCreatorCard
                createVaultCard
                privacyNote
                feedback
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var serverCard: some View {
        SettingsCard(title: "同步服务器", systemImage: "server.rack") {
            if store.hasBundledEndpoint {
                LabeledContent("服务器地址", value: store.endpointText)
                Text("地址由应用构建时配置，所有设备使用同一个 Worker。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("https://你的-worker.workers.dev", text: $store.endpointText)
                    .textFieldStyle(.roundedBorder)
                endpointGuidance
                HStack {
                    Button("保存服务器地址") {
                        store.saveManualEndpoint()
                    }
                    .disabled(store.endpointText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty)
                    Text("只需在第一台设备建立空间时填写一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var claimCodeCard: some View {
        SettingsCard(title: "输入配对码", systemImage: "rectangle.and.pencil.and.ellipsis") {
            switch store.shortCodeClaimPhase {
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
                    Text("配对码 5 分钟内有效，使用一次后失效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            case .claiming:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取配对码并认领设备…")
                }
            case let .awaitingConfirmation(code, deviceName, deadline):
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(deviceName) 已认领配对", systemImage: "laptopcomputer.and.iphone")
                    SixDigitCodeDisplay(code: code)
                    Text("请与另一台设备核对六位核对码完全一致；对方确认后本机自动加入。")
                        .foregroundStyle(.secondary)
                    expiryText(deadline)
                    Button("取消", role: .cancel) {
                        store.cancelShortCodeClaim()
                    }
                }
            case .confirmed:
                VStack(alignment: .leading, spacing: 10) {
                    Label("已通过六位码加入同步空间", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("本地任务会保留并重新同步到新空间。")
                        .foregroundStyle(.secondary)
                    Button("完成") {
                        store.cancelShortCodeClaim()
                    }
                }
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

    private var joinCreatorCard: some View {
        SettingsCard(title: "显示我的配对码", systemImage: "number.square") {
            switch store.joinCreatorPhase {
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机显示六位配对码，在另一台已同步设备上选择「输入新设备的配对码」并批准。")
                        .foregroundStyle(.secondary)
                    Button("生成配对码") {
                        Task { await store.createJoinRequest() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .creating:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在创建 5 分钟配对请求…")
                }
            case .waitingApproval(let invitation):
                VStack(alignment: .leading, spacing: 10) {
                    Text("六位配对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SixDigitCodeDisplay(code: invitation.shortCode)
                    Text("在另一台已同步设备上输入这 6 位数字。")
                        .foregroundStyle(.secondary)
                    expiryText(invitation.expiresAt)
                    Button("取消", role: .cancel) {
                        Task { await store.cancelJoinCreation() }
                    }
                }
            case .awaitingConfirmation(let verification):
                VStack(alignment: .leading, spacing: 10) {
                    Label("核对码", systemImage: "checkmark.shield")
                    SixDigitCodeDisplay(code: verification.code)
                    if store.joinCreatorApprovalPending {
                        Text("对方已批准。请确认另一台设备显示相同的六位核对码后加入同步空间。")
                            .foregroundStyle(.secondary)
                        Button("核对一致，加入同步空间") {
                            Task { await store.confirmJoinCreation() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("请与另一台设备核对六位核对码完全一致，等待对方批准。")
                            .foregroundStyle(.secondary)
                    }
                    expiryText(verification.expiresAt)
                    Button("取消", role: .cancel) {
                        Task { await store.cancelJoinCreation() }
                    }
                }
            case .approved(let vaultId, _):
                VStack(alignment: .leading, spacing: 10) {
                    Label("已加入同步空间", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("空间 \(shortened(vaultId))。其他设备会陆续看到新任务。")
                        .foregroundStyle(.secondary)
                    Button("完成") {
                        store.resetJoinCreation()
                    }
                }
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
                    Text("配对已取消，配对码将在 5 分钟后失效。")
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

    private var createVaultCard: some View {
        SettingsCard(title: "建立同步空间", systemImage: "lock.shield") {
            Text("第一台设备用部署者提供的邀请码创建同步空间；之后所有设备只需要六位配对码。")
                .foregroundStyle(.secondary)
            SecureField("部署同步服务时设置的邀请码", text: $vaultCreationInviteCode)
                .textFieldStyle(.roundedBorder)
            Text("邀请码须为 16–256 个无空格可打印 ASCII 字符，且只随本次请求发送、不会保存。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                let submitted = vaultCreationInviteCode
                Task {
                    await store.createVault(inviteCode: submitted)
                    if store.connection != nil {
                        vaultCreationInviteCode = ""
                    }
                }
            } label: {
                if store.isCreatingVault {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("建立同步空间", systemImage: "lock.shield")
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
        }
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

    // MARK: - 已配对

    private func configuredContent(_ connection: SyncConnectionSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    "跨设备",
                    "任务在设备间端到端加密同步。添加设备时两端会显示同一个六位核对码，核对一致后再批准。配对码 5 分钟内有效。"
                )
                spaceCard(connection)
                pathAPairingCard
                pathBApproverCard
                devicesCard
                privacyNote
                feedback
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func spaceCard(_ connection: SyncConnectionSummary) -> some View {
        SettingsCard(title: "同步空间", systemImage: "lock.shield.fill") {
            LabeledContent("空间", value: shortened(connection.vaultId))
            LabeledContent("当前设备", value: currentDeviceLabel(connection))
            LabeledContent("服务器", value: connection.endpoint.absoluteString)
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
                    Label("游标 \(summary.finalCursor)", systemImage: "number")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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

    private var pathAPairingCard: some View {
        SettingsCard(title: "显示配对码（本机等待新设备）", systemImage: "number.square") {
            switch store.pairingPhase {
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机显示六位配对码；在新设备上选择「输入配对码」，两端核对一致后由本机确认绑定。")
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
            case .awaitingClaim(let invitation):
                VStack(alignment: .leading, spacing: 10) {
                    if let shortCode = store.pairingShortCode {
                        Text("六位配对码")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SixDigitCodeDisplay(code: shortCode)
                    }
                    Text("等待另一台设备输入配对码")
                        .font(.headline)
                    Text("接入后两端都会显示同一个六位核对码；暂时不要关闭任一端。")
                        .foregroundStyle(.secondary)
                    expiryText(invitation.expiresAt)
                    Button("取消显示", role: .cancel) {
                        store.resetPairing()
                    }
                }
            case .awaitingVerification(let verification):
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "\(verification.deviceName) 已输入配对码",
                        systemImage: verification.platform == .android
                            ? "smartphone"
                            : "laptopcomputer"
                    )
                    SixDigitCodeDisplay(code: verification.code)
                    Text("请核对两端显示的六位核对码完全一致。只有一致时才允许传递同步密钥。")
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

    private var pathBApproverCard: some View {
        SettingsCard(title: "输入新设备的配对码", systemImage: "rectangle.and.pencil.and.ellipsis") {
            switch store.joinApproverPhase {
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
            case .awaitingConfirmation(let verification):
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "\(verification.deviceName) · \(platformName(verification.platform))",
                        systemImage: verification.platform == .android
                            ? "smartphone"
                            : "laptopcomputer"
                    )
                    SixDigitCodeDisplay(code: verification.code)
                    Text("请与新设备核对六位核对码完全一致，再批准加入。")
                        .foregroundStyle(.secondary)
                    expiryText(verification.expiresAt)
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
                    Text("新设备会自动执行首次同步，设备列表已刷新。")
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

    private var devicesCard: some View {
        SettingsCard(title: "设备", systemImage: "laptopcomputer.and.iphone") {
            HStack {
                Text("移除会立即停止该设备的同步；设备上的本地任务不会被删除。")
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
                        Image(systemName: device.platform == .macos
                            ? "laptopcomputer"
                            : "smartphone")
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
                            }
                            Text(deviceDetail(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !isCurrentDevice(device) {
                            Button("移除", role: .destructive) {
                                devicePendingRemoval = device
                            }
                            .disabled(store.cleaningDeviceIDs.contains(device.id))
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("退出后本机停止同步，本地任务保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出此同步空间", role: .destructive) {
                    showsExitConfirmation = true
                }
                .disabled(store.isExitingSpace)
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "同步密钥与设备令牌保存在本机加密凭据文件中；服务端只能看到端到端加密的任务密文。",
            systemImage: "key.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var endpointGuidance: some View {
        switch store.endpointSetupAssessment {
        case .empty:
            Label("请输入所有设备都能访问的 HTTPS Worker 根地址。", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .invalid:
            Label(
                "地址格式无效；必须使用 https://，不能包含账号、查询参数、路径或 #片段，也不能是局域网或回环地址。",
                systemImage: "xmark.circle.fill"
            )
            .foregroundStyle(.red)
        case .includesAPIVersion:
            Label("请删除末尾的 /v1，只填写 Worker 根地址。", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .ready(let endpoint):
            Label(
                "地址格式正确：\(endpoint.host ?? endpoint.absoluteString)。保存前请确认 Worker 已实际部署。",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
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
        Text("有效至 \(deadline.formatted(date: .omitted, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func expiryText(_ milliseconds: Int64) -> some View {
        expiryText(Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
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

    private func deviceDetail(_ device: DeviceInfo) -> String {
        var parts = [platformName(device.platform)]
        if let lastSeenAt = device.lastSeenAt {
            parts.append("最近在线 \(formattedMilliseconds(lastSeenAt))")
        } else {
            parts.append("创建于 \(formattedMilliseconds(device.createdAt))")
        }
        return parts.joined(separator: " · ")
    }

    private func currentDeviceLabel(_ connection: SyncConnectionSummary) -> String {
        if let current = store.devices.first(where: { isCurrentDevice($0) }) {
            return "\(current.name) · macOS"
        }
        return "macOS · \(shortened(connection.deviceId))"
    }

    private func formattedMilliseconds(_ value: Int64) -> String {
        Date(timeIntervalSince1970: Double(value) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func isCurrentDevice(_ device: DeviceInfo) -> Bool {
        device.isCurrent || device.id == store.connection?.deviceId
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

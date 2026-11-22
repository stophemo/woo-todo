import AppKit
import SwiftUI
import WooTodoCore

@MainActor
final class QuickAddPanelController: NSWindowController, NSWindowDelegate {
    let model: QuickAddModel
    private let dismissesOnResignKey: Bool
    private var previousApplication: NSRunningApplication?
    private var isDismissing = false

    init(store: TodayStore, dismissesOnResignKey: Bool = true) {
        self.dismissesOnResignKey = dismissesOnResignKey
        let panel = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 148)
        )
        model = QuickAddModel(store: store)
        super.init(window: panel)

        configurePanel(panel)
        configureContent(panel)
        panel.delegate = self
        panel.onPerformClose = { [weak self] in
            self?.dismiss(restorePreviousApplication: true)
        }
        model.onDismiss = { [weak self] in
            self?.dismiss(restorePreviousApplication: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建快速新增面板")
    }

    func show() {
        guard let panel = window else { return }
        let wasVisible = panel.isVisible
        if !wasVisible {
            model.prepareForPresentation()
            rememberFrontmostApplication()
            position(panel)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        model.requestFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard dismissesOnResignKey,
              let panel = window,
              panel.isVisible else { return }
        dismiss(restorePreviousApplication: false)
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.title = "快速新增任务"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func configureContent(_ panel: NSPanel) {
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]

        let hostingView = QuickAddHostingView(rootView: QuickAddView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.onHeightChange = { [weak self] height in
            Task { @MainActor [weak self] in
                self?.resizePanel(toContentHeight: height)
            }
        }
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
        ])
        panel.contentView = effectView
    }

    /// 内容折叠或展开时保持面板顶部位置不变，避免输入框在屏幕上跳动。
    private func resizePanel(toContentHeight height: CGFloat) {
        guard let panel = window else { return }
        let targetHeight = ceil(height)
        guard targetHeight > 0,
              abs(panel.frame.height - targetHeight) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - targetHeight
        frame.size.height = targetHeight
        panel.setFrame(frame, display: true)
    }

    private func position(_ panel: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let size = panel.frame.size
        let proposedOrigin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - visibleFrame.height * 0.24 - size.height / 2
        )
        panel.setFrameOrigin(NSPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        ))
    }

    private func rememberFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            previousApplication = nil
            return
        }
        previousApplication = application
    }

    private func dismiss(restorePreviousApplication: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }

        window?.orderOut(nil)
        let previous = previousApplication
        previousApplication = nil
        if restorePreviousApplication {
            previous?.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

@MainActor
final class QuickAddModel: ObservableObject {
    @Published var title = ""
    @Published var categoryName = ""
    @Published var isSchedulingExpanded = false {
        didSet { onLayoutChange?() }
    }
    @Published var dateRangeEnabled = false {
        didSet {
            if !dateRangeEnabled {
                reminderEnabled = false
                dailyRepeat = false
                endDateEnabled = false
            }
            onLayoutChange?()
        }
    }
    @Published var startDate = Calendar.current.startOfDay(for: Date())
    @Published var endDateEnabled = false {
        didSet { onLayoutChange?() }
    }
    @Published var endDate = Calendar.current.startOfDay(for: Date())
    @Published var reminderEnabled = false {
        didSet { onLayoutChange?() }
    }
    @Published var reminderDate = QuickAddModel.defaultReminderDate
    @Published var dailyRepeat = false {
        didSet { onLayoutChange?() }
    }
    @Published private(set) var categories: [TaskCategory] = TaskCategory.defaults
    @Published private(set) var errorMessage: String? {
        didSet { onLayoutChange?() }
    }
    @Published private(set) var focusRequest = 0

    var onDismiss: (() -> Void)?
    var onLayoutChange: (() -> Void)?

    private let store: TodayStore

    init(store: TodayStore) {
        self.store = store
    }

    func prepareForPresentation() {
        title = ""
        categoryName = ""
        categories = store.categories
        errorMessage = nil
        isSchedulingExpanded = false
        dateRangeEnabled = false
        endDateEnabled = false
        reminderEnabled = false
        dailyRepeat = false
        let today = Calendar.current.startOfDay(for: Date())
        startDate = today
        endDate = today
        reminderDate = Self.defaultReminderDate
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    func submit() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "任务内容不能为空"
            requestFocus()
            return
        }
        let start = dateRangeEnabled
            ? Calendar.current.startOfDay(for: startDate)
            : nil
        let end = dateRangeEnabled && endDateEnabled
            ? Calendar.current.startOfDay(for: endDate)
            : nil
        if let start, let end, start > end {
            errorMessage = "任务日期不能晚于结束日期"
            return
        }
        guard let categoryID = resolveCategoryID() else { return }
        guard store.add(
            title: title,
            categoryID: categoryID,
            startDate: start,
            endDate: end,
            reminderTime: resolvedReminderTime(),
            recurrence: dateRangeEnabled && dailyRepeat ? .daily : .once
        ) else {
            errorMessage = store.errorMessage ?? "无法新增任务"
            requestFocus()
            return
        }
        title = ""
        categoryName = ""
        errorMessage = nil
        onDismiss?()
    }

    func cancel() {
        title = ""
        categoryName = ""
        errorMessage = nil
        onDismiss?()
    }

    var schedulingSummary: String {
        guard dateRangeEnabled else { return "日期与提醒" }
        let start = startDate.formatted(.dateTime.month().day())
        var summary = start
        if endDateEnabled {
            let end = endDate.formatted(.dateTime.month().day())
            summary = "\(start) – \(end)"
        }
        if reminderEnabled {
            summary += " · \(reminderDate.formatted(.dateTime.hour().minute()))"
        }
        if dailyRepeat {
            summary += " · 每天"
        }
        return summary
    }

    private func resolvedReminderTime() -> TaskReminderTime? {
        guard dateRangeEnabled, reminderEnabled else { return nil }
        let components = Calendar.current.dateComponents(
            [.hour, .minute],
            from: reminderDate
        )
        guard let hour = components.hour, let minute = components.minute else {
            return nil
        }
        return try? TaskReminderTime(hour: hour, minute: minute)
    }

    private func resolveCategoryID() -> String? {
        guard !categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TaskCategory.inboxID
        }
        guard let category = store.addCategory(named: categoryName) else {
            errorMessage = store.errorMessage ?? "无法创建标签"
            return nil
        }
        categories = store.categories
        return category.id
    }

    private static var defaultReminderDate: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
            ?? Date()
    }
}

struct QuickAddView: View {
    @ObservedObject var model: QuickAddModel
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("新增任务", text: $model.title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isTitleFocused)
                    .onSubmit(model.submit)
                    .accessibilityLabel("任务内容")

                Button(action: model.submit) {
                    Image(systemName: "arrow.turn.down.left")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("添加任务")
                .accessibilityLabel("添加任务")
            }

            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                TextField("标签（可留空，输入新名称会自动创建）", text: $model.categoryName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit(model.submit)
                    .accessibilityLabel("标签")
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("新增失败：\(errorMessage)")
            }

            Button {
                model.isSchedulingExpanded.toggle()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.callout)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(model.schedulingSummary)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(model.isSchedulingExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.isSchedulingExpanded ? "收起日期与提醒" : "展开日期与提醒")
            .accessibilityLabel(model.isSchedulingExpanded ? "收起日期与提醒" : "展开日期与提醒")

            if model.isSchedulingExpanded {
                scheduleFields
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .onAppear {
            isTitleFocused = true
        }
        .onChange(of: model.focusRequest) { _, _ in
            isTitleFocused = true
        }
        .onExitCommand(perform: model.cancel)
        .onChange(of: model.startDate) { _, value in
            if model.endDate < value { model.endDate = value }
        }
        .onChange(of: model.endDateEnabled) { _, enabled in
            if enabled && model.endDate < model.startDate {
                model.endDate = model.startDate
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.isSchedulingExpanded)
    }

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("设置任务日期", isOn: $model.dateRangeEnabled)
            if model.dateRangeEnabled {
                DatePicker("任务日期", selection: $model.startDate, displayedComponents: .date)
                Toggle("设置结束日期", isOn: $model.endDateEnabled)
                if model.endDateEnabled {
                    DatePicker("结束日期", selection: $model.endDate, displayedComponents: .date)
                    if model.startDate > model.endDate {
                        Text("任务日期不能晚于结束日期")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Toggle("每天重复", isOn: $model.dailyRepeat)
                if model.dailyRepeat {
                    Text("每天生成一条新任务；前一天未完成会自动记为放弃。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("在指定时间提醒", isOn: $model.reminderEnabled)
                if model.reminderEnabled {
                    DatePicker(
                        "提醒时间",
                        selection: $model.reminderDate,
                        displayedComponents: .hourAndMinute
                    )
                    Text("提醒会在任务日期当天的这个时间触发。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private final class QuickAddHostingView: NSHostingView<QuickAddView> {
    var onHeightChange: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0

    override func layout() {
        super.layout()
        let height = bounds.height
        guard height > 0, abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        onHeightChange?(height)
    }
}

private final class QuickAddPanel: NSPanel {
    var onPerformClose: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        if let onPerformClose {
            onPerformClose()
        } else {
            super.performClose(sender)
        }
    }
}

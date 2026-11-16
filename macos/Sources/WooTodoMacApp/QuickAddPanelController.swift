import AppKit
import SwiftUI
import WooTodoCore

@MainActor
final class QuickAddPanelController: NSWindowController, NSWindowDelegate {
    private let model: QuickAddModel
    private var previousApplication: NSRunningApplication?
    private var isDismissing = false

    init(store: TodayStore) {
        let panel = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 176)
        )
        model = QuickAddModel(store: store)
        super.init(window: panel)

        configurePanel(panel)
        configureContent(panel)
        panel.delegate = self
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
        guard let panel = window, panel.isVisible else { return }
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

        let hostingView = NSHostingView(rootView: QuickAddView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        panel.contentView = effectView
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
private final class QuickAddModel: ObservableObject {
    @Published var title = ""
    @Published var categoryName = ""
    @Published private(set) var categories: [TaskCategory] = TaskCategory.defaults
    @Published private(set) var errorMessage: String?
    @Published private(set) var focusRequest = 0

    var onDismiss: (() -> Void)?

    private let store: TodayStore

    init(store: TodayStore) {
        self.store = store
    }

    func prepareForPresentation() {
        title = ""
        categoryName = ""
        categories = store.categories
        errorMessage = nil
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
        guard let categoryID = resolveCategoryID() else { return }
        guard store.add(title: title, categoryID: categoryID) else {
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

    var selectionSummary: String {
        let name = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "无标签 · 完成即止" }
        if let matched = categories.first(where: {
            $0.name.compare(
                name,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) {
            return "\(matched.name) · 完成即止"
        }
        return "\(name) · 完成即止"
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
}

private struct QuickAddView: View {
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
                    .accessibilityHidden(true)

                TextField("标签（可留空，输入新名称会自动创建）", text: $model.categoryName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit(model.submit)
                    .accessibilityLabel("标签")
            }

            Group {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityLabel("新增失败：\(errorMessage)")
                } else {
                    Text(model.selectionSummary)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .frame(height: 16)
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
    }
}

private final class QuickAddPanel: NSPanel {
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
}

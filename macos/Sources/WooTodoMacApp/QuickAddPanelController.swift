import AppKit
import SwiftUI
import WooTodoCore

@MainActor
final class QuickAddPanelController: NSWindowController {
    private let model: QuickAddModel
    private var previousApplication: NSRunningApplication?

    init(store: TodayStore) {
        let panel = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 92)
        )
        model = QuickAddModel(store: store)
        super.init(window: panel)

        configurePanel(panel)
        configureContent(panel)
        model.onDismiss = { [weak self] in
            self?.dismissAndRestorePreviousApplication()
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

    private func configurePanel(_ panel: NSPanel) {
        panel.title = "快速新增任务"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
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
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
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

    private func dismissAndRestorePreviousApplication() {
        window?.orderOut(nil)
        previousApplication?.activate(options: [.activateIgnoringOtherApps])
        previousApplication = nil
    }
}

@MainActor
private final class QuickAddModel: ObservableObject {
    @Published var title = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var focusRequest = 0

    var onDismiss: (() -> Void)?

    private let store: TodayStore

    init(store: TodayStore) {
        self.store = store
    }

    func prepareForPresentation() {
        title = ""
        errorMessage = nil
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    func submit() {
        guard store.add(title: title, tier: .mainline, repeatsDaily: false) else {
            errorMessage = store.errorMessage ?? "无法新增任务"
            requestFocus()
            return
        }
        title = ""
        errorMessage = nil
        onDismiss?()
    }

    func cancel() {
        title = ""
        errorMessage = nil
        onDismiss?()
    }
}

private struct QuickAddView: View {
    @ObservedObject var model: QuickAddModel
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("新增今日任务", text: $model.title)
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

            Group {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityLabel("新增失败：\(errorMessage)")
                } else {
                    Text("今日 · 主线")
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

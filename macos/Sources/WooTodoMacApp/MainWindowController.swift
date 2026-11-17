import AppKit
import SwiftUI
import WooTodoCore

@MainActor
enum WindowFramePolicy {
    /// 恢复上次位置；屏幕拔插后把窗口约束回可见区域，首次打开则居中。
    static func restore(_ window: NSWindow, name: String) {
        guard window.setFrameUsingName(name) else {
            window.center()
            return
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame {
            window.setFrame(frame, display: false)
        }
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let store: DashboardStore
    private let navigation: MainWindowNavigation
    private var hasRestoredFrame = false
    private var needsReload = true
    var onClose: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }
    var isVisibleOrMiniaturized: Bool {
        window?.isVisible == true || window?.isMiniaturized == true
    }
    var currentSection: MainWindowSection { navigation.selection }

    init(
        store: DashboardStore,
        dayCounterStore: DayCounterStore,
        initialSection: MainWindowSection = .today,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        navigation = MainWindowNavigation(selection: initialSection)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Woo Todo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // 内容区必须保持不透明；否则侧栏透明会连桌面或后方应用文字一起透出。
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        // 主窗口用隐藏/显示切换，不进入全屏，避免 orderOut 全屏窗口留下空白 Space。
        window.collectionBehavior = [.fullScreenNone]
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WooTodoMainWindow")
        window.contentView = NSHostingView(rootView: MainWindowView(
            store: store,
            dayCounterStore: dayCounterStore,
            navigation: navigation,
            openSettings: openSettings
        ))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建主窗口")
    }

    func show(section: MainWindowSection = .today) {
        navigation.selection = section
        reloadContent()
        if let window {
            if !hasRestoredFrame {
                WindowFramePolicy.restore(window, name: "WooTodoMainWindow")
                hasRestoredFrame = true
            }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?()
    }

    func hide() {
        window?.orderOut(nil)
        onVisibilityChange?()
    }

    func toggleVisibility() {
        isVisible ? hide() : show(section: navigation.selection)
    }

    /// 窗口隐藏时只记脏，不做任何仓储刷新和 SwiftUI 更新，避免后台空转。
    func reloadIfVisible() {
        guard isVisible else {
            needsReload = true
            return
        }
        reloadContent()
    }

    private func reloadContent() {
        store.reload()
        if navigation.selection == .trash {
            store.reloadTrash()
        } else if navigation.selection == .statistics {
            store.reloadStatisticsIfNeeded()
        }
        needsReload = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if needsReload {
            reloadContent()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onVisibilityChange?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        reloadIfVisible()
        onVisibilityChange?()
    }

    /// ⌘W 只收起主窗口，保留窗口与滚动状态，菜单栏可再次显示。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil else { return false }
        hide()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
        onVisibilityChange?()
    }
}

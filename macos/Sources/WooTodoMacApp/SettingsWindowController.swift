import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation: SettingsNavigation
    private var hasRestoredFrame = false
    var onClose: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    var isVisibleOrMiniaturized: Bool {
        window?.isVisible == true || window?.isMiniaturized == true
    }

    init(
        syncSettingsStore: SyncSettingsStore,
        dayCounterStore: DayCounterStore,
        dailyDigestSettingsStore: DailyDigestSettingsStore,
        shortcutSettingsStore: ShortcutSettingsStore,
        mcpSettingsStore: MCPSettingsStore,
        localDataManager: LocalDataManager,
        initialSection: SettingsSection = .display
    ) {
        navigation = SettingsNavigation(selection: initialSection)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Woo Todo 设置"
        window.collectionBehavior = [.fullScreenNone]
        window.minSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WooTodoSettingsWindow")
        window.contentView = NSHostingView(rootView: SettingsView(
            syncSettingsStore: syncSettingsStore,
            dayCounterStore: dayCounterStore,
            dailyDigestSettingsStore: dailyDigestSettingsStore,
            shortcutSettingsStore: shortcutSettingsStore,
            mcpSettingsStore: mcpSettingsStore,
            localDataManager: localDataManager,
            navigation: navigation
        ))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建设置窗口")
    }

    func show(section: SettingsSection = .display) {
        navigation.selection = section
        if let window {
            if !hasRestoredFrame {
                WindowFramePolicy.restore(window, name: "WooTodoSettingsWindow")
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

    func windowDidMiniaturize(_ notification: Notification) {
        onVisibilityChange?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onVisibilityChange?()
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
        onVisibilityChange?()
    }
}

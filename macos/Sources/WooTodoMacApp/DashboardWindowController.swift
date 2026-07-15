import AppKit
import SwiftUI
import WooTodoCore

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let store: DashboardStore
    var onClose: (() -> Void)?

    init(store: DashboardStore, syncSettingsStore: SyncSettingsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Woo Todo · 任务详情与统计"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WooTodoDashboardWindow")
        window.contentView = NSHostingView(rootView: DashboardView(
            store: store,
            syncSettingsStore: syncSettingsStore
        ))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建管理窗口")
    }

    func show() {
        store.reload()
        if let window, !window.setFrameUsingName("WooTodoDashboardWindow") {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        store.reload()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.reload()
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
    }
}

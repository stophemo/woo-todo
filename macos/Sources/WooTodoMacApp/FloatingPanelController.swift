import AppKit
import SwiftUI
import WooTodoCore

@MainActor
final class FloatingPanelController: NSWindowController {
    private enum PreferenceKey {
        static let blurEnabled = "panel.blurEnabled"
        static let clickThrough = "panel.clickThrough"
        static let alwaysOnTop = "panel.alwaysOnTop"
    }

    private let defaults: UserDefaults
    private let effectView = NSVisualEffectView()
    var onStateChange: (() -> Void)?

    private(set) var isBlurEnabled: Bool
    private(set) var isClickThrough: Bool
    private(set) var isAlwaysOnTop: Bool

    init(store: TodayStore, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            PreferenceKey.blurEnabled: true,
            PreferenceKey.clickThrough: false,
            PreferenceKey.alwaysOnTop: true
        ])
        isBlurEnabled = defaults.bool(forKey: PreferenceKey.blurEnabled)
        isClickThrough = defaults.bool(forKey: PreferenceKey.clickThrough)
        isAlwaysOnTop = defaults.bool(forKey: PreferenceKey.alwaysOnTop)

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520)
        )
        super.init(window: panel)

        configurePanel(panel)
        configureContent(store: store)
        applyVisualState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建悬浮面板")
    }

    func show() {
        guard let window else { return }
        if !window.setFrameUsingName("WooTodoFloatingPanel") {
            window.center()
        }
        window.orderFrontRegardless()
    }

    func makeInteractive() {
        setClickThrough(false)
        show()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
    }

    func toggleInteraction() {
        if isClickThrough {
            makeInteractive()
        } else {
            setClickThrough(true)
        }
    }

    func toggleBlur() {
        isBlurEnabled.toggle()
        defaults.set(isBlurEnabled, forKey: PreferenceKey.blurEnabled)
        applyVisualState()
    }

    func toggleClickThrough() {
        setClickThrough(!isClickThrough)
    }

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        defaults.set(isAlwaysOnTop, forKey: PreferenceKey.alwaysOnTop)
        applyVisualState()
    }

    private func setClickThrough(_ enabled: Bool) {
        isClickThrough = enabled
        defaults.set(enabled, forKey: PreferenceKey.clickThrough)
        applyVisualState()
    }

    private func configurePanel(_ panel: FloatingPanel) {
        panel.title = "Woo Todo"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("WooTodoFloatingPanel")
        panel.minSize = NSSize(width: 300, height: 360)
    }

    private func configureContent(store: TodayStore) {
        guard let panel = window else { return }
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: TodayView(store: store))
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

    private func applyVisualState() {
        guard let panel = window else { return }
        panel.level = isAlwaysOnTop ? .floating : .normal
        panel.ignoresMouseEvents = isClickThrough
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(
            isBlurEnabled ? 0.04 : 0.24
        )
        effectView.isHidden = !isBlurEnabled
        if !isBlurEnabled {
            // 关闭毛玻璃时仍保留轻微透明底色，确保文字可读。
            panel.contentView?.isHidden = false
            effectView.isHidden = false
            effectView.material = .contentBackground
            effectView.state = .inactive
        } else {
            effectView.material = .hudWindow
            effectView.state = .active
        }
        onStateChange?()
    }
}

private final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

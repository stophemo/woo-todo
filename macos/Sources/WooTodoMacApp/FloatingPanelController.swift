import AppKit
import SwiftUI
import WooTodoCore

enum PanelOpacityPolicy {
    static let minimum: CGFloat = 0.2
    static let maximum: CGFloat = 1
    static let defaultValue: CGFloat = 1
    static let adjustmentStep: CGFloat = 0.1

    static func normalized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultValue }
        return min(max(value, minimum), maximum)
    }

    static func adjusted(_ value: CGFloat, by delta: CGFloat) -> CGFloat {
        normalized(value + delta)
    }
}

@MainActor
final class FloatingPanelController: NSWindowController {
    private enum PreferenceKey {
        static let blurEnabled = "panel.blurEnabled"
        static let clickThrough = "panel.clickThrough"
        static let alwaysOnTop = "panel.alwaysOnTop"
        static let opacity = "panel.opacity"
    }

    private let defaults: UserDefaults
    private let contentContainer = NSView()
    private let solidBackgroundView = AppearanceAwareBackgroundView()
    private let effectView = NSVisualEffectView()
    var onStateChange: (() -> Void)?

    private(set) var isBlurEnabled: Bool
    private(set) var isClickThrough: Bool
    private(set) var isAlwaysOnTop: Bool
    private(set) var panelOpacity: CGFloat
    var isVisible: Bool { window?.isVisible == true }

    init(
        store: TodayStore,
        dayCounterStore: DayCounterStore,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        defaults.register(defaults: [
            PreferenceKey.blurEnabled: true,
            PreferenceKey.clickThrough: false,
            PreferenceKey.alwaysOnTop: true,
            PreferenceKey.opacity: Double(PanelOpacityPolicy.defaultValue)
        ])
        isBlurEnabled = defaults.bool(forKey: PreferenceKey.blurEnabled)
        isClickThrough = defaults.bool(forKey: PreferenceKey.clickThrough)
        isAlwaysOnTop = defaults.bool(forKey: PreferenceKey.alwaysOnTop)
        panelOpacity = PanelOpacityPolicy.normalized(
            CGFloat(defaults.double(forKey: PreferenceKey.opacity))
        )

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520)
        )
        super.init(window: panel)

        configurePanel(panel)
        configureContent(store: store, dayCounterStore: dayCounterStore)
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
        onStateChange?()
    }

    func hide() {
        window?.orderOut(nil)
        onStateChange?()
    }

    func toggleVisibility() {
        isVisible ? hide() : show()
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

    func setPanelOpacity(_ opacity: CGFloat) {
        let normalized = PanelOpacityPolicy.normalized(opacity)
        guard panelOpacity != normalized else { return }
        panelOpacity = normalized
        defaults.set(Double(normalized), forKey: PreferenceKey.opacity)
        applyVisualState()
    }

    func increasePanelOpacity() {
        adjustPanelOpacity(by: PanelOpacityPolicy.adjustmentStep)
    }

    func decreasePanelOpacity() {
        adjustPanelOpacity(by: -PanelOpacityPolicy.adjustmentStep)
    }

    private func adjustPanelOpacity(by delta: CGFloat) {
        setPanelOpacity(PanelOpacityPolicy.adjusted(panelOpacity, by: delta))
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

    private func configureContent(store: TodayStore, dayCounterStore: DayCounterStore) {
        guard let panel = window else { return }
        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = 8
        contentContainer.layer?.masksToBounds = true

        solidBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.translatesAutoresizingMaskIntoConstraints = false

        let hostingView = NSHostingView(
            rootView: TodayView(store: store, dayCounterStore: dayCounterStore)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(solidBackgroundView)
        contentContainer.addSubview(effectView)
        contentContainer.addSubview(hostingView)
        NSLayoutConstraint.activate([
            solidBackgroundView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            solidBackgroundView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            solidBackgroundView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            solidBackgroundView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        panel.contentView = contentContainer
    }

    private func applyVisualState() {
        guard let panel = window else { return }
        panel.level = isAlwaysOnTop ? .floating : .normal
        panel.ignoresMouseEvents = isClickThrough
        panel.alphaValue = panelOpacity
        panel.backgroundColor = .clear
        effectView.isHidden = !isBlurEnabled
        solidBackgroundView.isHidden = isBlurEnabled
        solidBackgroundView.refreshColor()
        onStateChange?()
    }
}

private final class AppearanceAwareBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建动态背景")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    func refreshColor() {
        layer?.backgroundColor = NSColor(
            srgbRed: 37 / 255,
            green: 39 / 255,
            blue: 37 / 255,
            alpha: 1
        ).cgColor
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

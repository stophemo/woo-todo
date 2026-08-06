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

enum PanelPresentation: Equatable {
    case desktopWidget
    case normal
    case alwaysOnTop
}

enum PanelPresentationPolicy {
    static func resolve(
        isDesktopWidget: Bool,
        isAlwaysOnTop: Bool
    ) -> PanelPresentation {
        if isDesktopWidget { return .desktopWidget }
        return isAlwaysOnTop ? .alwaysOnTop : .normal
    }
}

enum PanelInteractionPolicy {
    static func clickThroughEnabled(
        isDesktopWidget: Bool,
        requestedClickThrough: Bool
    ) -> Bool {
        !isDesktopWidget && requestedClickThrough
    }
}

enum PanelFramePolicy {
    static let autosaveName = "WooTodoFloatingPanel"
    static let currentLayoutVersion = 2
    static let defaultSize = NSSize(width: 610, height: 440)
    static let legacyDefaultSize = NSSize(width: 360, height: 520)

    static func usesLegacyDefaultSize(_ size: NSSize) -> Bool {
        abs(size.width - legacyDefaultSize.width) < 0.5
            && abs(size.height - legacyDefaultSize.height) < 0.5
    }

    static func migratedFrame(from frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(defaultSize.width, visibleFrame.width),
            height: min(defaultSize.height, visibleFrame.height)
        )
        let proposedOrigin = NSPoint(
            x: frame.maxX - size.width,
            y: frame.maxY - size.height
        )
        return NSRect(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }
}

enum PanelResizePolicy {
    static func resizedFrame(
        initialFrame: NSRect,
        mouseDelta: NSPoint,
        minimumSize: NSSize
    ) -> NSRect {
        NSRect(
            x: initialFrame.minX,
            y: initialFrame.minY,
            width: max(minimumSize.width, initialFrame.width + mouseDelta.x),
            height: max(minimumSize.height, initialFrame.height + mouseDelta.y)
        )
    }
}

@MainActor
final class FloatingPanelController: NSWindowController {
    private enum PreferenceKey {
        static let blurEnabled = "panel.blurEnabled"
        static let clickThrough = "panel.clickThrough"
        static let alwaysOnTop = "panel.alwaysOnTop"
        static let desktopWidget = "panel.desktopWidget"
        static let opacity = "panel.opacity"
        static let frameLayoutVersion = "panel.frameLayoutVersion"
    }

    private let defaults: UserDefaults
    private let contentContainer = NSView()
    private let solidBackgroundView = AppearanceAwareBackgroundView()
    private let effectView = NSVisualEffectView()
    private let blurTintView = NSView()
    private let resizeHandle = WidgetResizeHandleView()
    var onStateChange: (() -> Void)?

    private(set) var isBlurEnabled: Bool
    private(set) var isClickThrough: Bool
    private(set) var isAlwaysOnTop: Bool
    private(set) var isDesktopWidget: Bool
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
            PreferenceKey.alwaysOnTop: false,
            PreferenceKey.desktopWidget: true,
            PreferenceKey.opacity: Double(PanelOpacityPolicy.defaultValue)
        ])
        isBlurEnabled = defaults.bool(forKey: PreferenceKey.blurEnabled)
        isDesktopWidget = defaults.bool(forKey: PreferenceKey.desktopWidget)
        isClickThrough = PanelInteractionPolicy.clickThroughEnabled(
            isDesktopWidget: isDesktopWidget,
            requestedClickThrough: defaults.bool(forKey: PreferenceKey.clickThrough)
        )
        isAlwaysOnTop = !isDesktopWidget && defaults.bool(forKey: PreferenceKey.alwaysOnTop)
        panelOpacity = PanelOpacityPolicy.normalized(
            CGFloat(defaults.double(forKey: PreferenceKey.opacity))
        )
        defaults.set(isClickThrough, forKey: PreferenceKey.clickThrough)

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: PanelFramePolicy.defaultSize)
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
        if window.setFrameUsingName(PanelFramePolicy.autosaveName) {
            migratePanelFrameIfNeeded(window)
        } else {
            positionForFirstPresentation(window)
            defaults.set(
                PanelFramePolicy.currentLayoutVersion,
                forKey: PreferenceKey.frameLayoutVersion
            )
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
        if isDesktopWidget {
            isDesktopWidget = false
            isAlwaysOnTop = true
        } else {
            isAlwaysOnTop.toggle()
        }
        defaults.set(isDesktopWidget, forKey: PreferenceKey.desktopWidget)
        defaults.set(isAlwaysOnTop, forKey: PreferenceKey.alwaysOnTop)
        applyVisualState()
    }

    func toggleDesktopWidget() {
        isDesktopWidget.toggle()
        if isDesktopWidget {
            isAlwaysOnTop = false
            isClickThrough = false
        }
        defaults.set(isDesktopWidget, forKey: PreferenceKey.desktopWidget)
        defaults.set(isAlwaysOnTop, forKey: PreferenceKey.alwaysOnTop)
        defaults.set(isClickThrough, forKey: PreferenceKey.clickThrough)
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
        if enabled && isDesktopWidget {
            isDesktopWidget = false
            defaults.set(false, forKey: PreferenceKey.desktopWidget)
        }
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
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow
        panel.setFrameAutosaveName(PanelFramePolicy.autosaveName)
        panel.minSize = NSSize(width: 300, height: 360)
    }

    private func configureContent(store: TodayStore, dayCounterStore: DayCounterStore) {
        guard let panel = window else { return }
        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = 8
        contentContainer.layer?.borderWidth = 1
        contentContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        contentContainer.layer?.masksToBounds = true
        resizeHandle.panel = panel
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        solidBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        blurTintView.wantsLayer = true
        blurTintView.layer?.backgroundColor = NSColor(
            srgbRed: 35 / 255,
            green: 38 / 255,
            blue: 36 / 255,
            alpha: 0.82
        ).cgColor
        blurTintView.translatesAutoresizingMaskIntoConstraints = false

        let hostingView = InteractiveHostingView(
            rootView: TodayView(store: store, dayCounterStore: dayCounterStore)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(solidBackgroundView)
        contentContainer.addSubview(effectView)
        contentContainer.addSubview(blurTintView)
        contentContainer.addSubview(hostingView)
        contentContainer.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            solidBackgroundView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            solidBackgroundView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            solidBackgroundView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            solidBackgroundView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            blurTintView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            blurTintView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            blurTintView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            blurTintView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 16),
            resizeHandle.heightAnchor.constraint(equalToConstant: 16)
        ])
        panel.contentView = contentContainer
    }

    private func applyVisualState() {
        guard let panel = window else { return }
        switch PanelPresentationPolicy.resolve(
            isDesktopWidget: isDesktopWidget,
            isAlwaysOnTop: isAlwaysOnTop
        ) {
        case .desktopWidget:
            panel.level = NSWindow.Level(
                rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            )
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .normal:
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case .alwaysOnTop:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        panel.ignoresMouseEvents = isClickThrough
        panel.alphaValue = panelOpacity
        panel.backgroundColor = .clear
        effectView.isHidden = !isBlurEnabled
        blurTintView.isHidden = !isBlurEnabled
        solidBackgroundView.isHidden = isBlurEnabled
        resizeHandle.isHidden = !isDesktopWidget
        solidBackgroundView.refreshColor()
        onStateChange?()
    }

    private func positionForFirstPresentation(_ panel: NSWindow) {
        guard isDesktopWidget, let visibleFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.minX + 24,
            y: visibleFrame.maxY - panel.frame.height - 24
        ))
    }

    private func migratePanelFrameIfNeeded(_ panel: NSWindow) {
        guard defaults.integer(forKey: PreferenceKey.frameLayoutVersion)
                < PanelFramePolicy.currentLayoutVersion else {
            return
        }
        defer {
            defaults.set(
                PanelFramePolicy.currentLayoutVersion,
                forKey: PreferenceKey.frameLayoutVersion
            )
        }
        guard PanelFramePolicy.usesLegacyDefaultSize(panel.frame.size),
              let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }
        panel.setFrame(
            PanelFramePolicy.migratedFrame(from: panel.frame, visibleFrame: visibleFrame),
            display: true
        )
        panel.saveFrame(usingName: PanelFramePolicy.autosaveName)
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

final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class WidgetResizeHandleView: NSView {
    weak var panel: NSWindow?

    private var initialFrame: NSRect?
    private var initialMouseLocation: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        initialFrame = panel.frame
        initialMouseLocation = screenLocation(for: event, in: panel)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel,
              let initialFrame,
              let initialMouseLocation else {
            return
        }
        let currentMouseLocation = screenLocation(for: event, in: panel)
        panel.setFrame(
            PanelResizePolicy.resizedFrame(
                initialFrame: initialFrame,
                mouseDelta: NSPoint(
                    x: currentMouseLocation.x - initialMouseLocation.x,
                    y: currentMouseLocation.y - initialMouseLocation.y
                ),
                minimumSize: panel.minSize
            ),
            display: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        panel?.saveFrame(usingName: PanelFramePolicy.autosaveName)
        initialFrame = nil
        initialMouseLocation = nil
    }

    private func screenLocation(for event: NSEvent, in panel: NSWindow) -> NSPoint {
        panel.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
    }
}

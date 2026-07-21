import AppKit
import Carbon.HIToolbox
import SwiftUI
import WooTodoCore

struct ShortcutRecorder: NSViewRepresentable {
    let binding: GlobalShortcutBinding
    let onCapture: (GlobalShortcutBinding) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onCapture = context.coordinator.capture
        button.update(binding)
        return button
    }

    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        context.coordinator.onCapture = onCapture
        view.onCapture = context.coordinator.capture
        view.update(binding)
    }

    final class Coordinator {
        var onCapture: (GlobalShortcutBinding) -> Void

        init(onCapture: @escaping (GlobalShortcutBinding) -> Void) {
            self.onCapture = onCapture
        }

        func capture(_ binding: GlobalShortcutBinding) {
            onCapture(binding)
        }
    }
}

final class ShortcutRecorderButton: NSButton {
    var onCapture: ((GlobalShortcutBinding) -> Void)?

    private var binding: GlobalShortcutBinding?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        alignment = .center
        focusRingType = .exterior
        toolTip = "点击后按下新的全局快捷键"
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 130, height: 28))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建快捷键录制控件")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 138, height: 28)
    }

    func update(_ binding: GlobalShortcutBinding) {
        self.binding = binding
        if !isRecording {
            title = binding.displayValue
        }
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        title = "请按快捷键…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            return
        }
        let modifiers = GlobalShortcutModifiers(event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            title = "请包含修饰键"
            return
        }
        guard let keyLabel = ShortcutKeyLabel.value(for: event) else {
            NSSound.beep()
            return
        }
        let captured = GlobalShortcutBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: keyLabel
        )
        onCapture?(captured)
        binding = captured
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        isRecording = false
        title = binding?.displayValue ?? "点击录入"
    }
}

private extension GlobalShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var value: GlobalShortcutModifiers = []
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        if normalized.contains(.shift) { value.insert(.shift) }
        if normalized.contains(.control) { value.insert(.control) }
        if normalized.contains(.option) { value.insert(.option) }
        if normalized.contains(.command) { value.insert(.command) }
        self = value
    }
}

private enum ShortcutKeyLabel {
    static func value(for event: NSEvent) -> String? {
        let keyCode = Int(event.keyCode)
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            if let functionLabel = functionKeyLabel(keyCode) {
                return functionLabel
            }
            guard let characters = event.charactersIgnoringModifiers?.uppercased(),
                  !characters.isEmpty else { return nil }
            return String(characters.prefix(1))
        }
    }

    private static func functionKeyLabel(_ keyCode: Int) -> String? {
        let labels: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        return labels[keyCode]
    }
}

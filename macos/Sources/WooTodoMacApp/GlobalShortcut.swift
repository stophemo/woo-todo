import Carbon.HIToolbox
import Foundation

public enum GlobalShortcutError: LocalizedError {
    case installHandlerFailed(OSStatus)
    case registerFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .installHandlerFailed(status):
            "无法安装全局快捷键处理器（错误码 \(status)）"
        case let .registerFailed(status):
            "无法注册全局快捷键（错误码 \(status)）"
        }
    }
}

/// 基于 Carbon Hot Key，避免键盘监听权限和常驻事件轮询。
@MainActor
final class GlobalShortcut {
    private static let signature: OSType = 0x57544F44 // “WTOD”
    private static var nextIdentifier: UInt32 = 1

    private let resources = Resources()
    private let identifier: UInt32
    private let action: () -> Void

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void
    ) throws {
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                return MainActor.assumeIsolated {
                    let shortcut = Unmanaged<GlobalShortcut>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    guard hotKeyID.signature == GlobalShortcut.signature,
                          hotKeyID.id == shortcut.identifier else {
                        return OSStatus(eventNotHandledErr)
                    }
                    shortcut.action()
                    return noErr
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &resources.eventHandler
        )
        guard handlerStatus == noErr else {
            throw GlobalShortcutError.installHandlerFailed(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &resources.hotKey
        )
        guard registerStatus == noErr else {
            resources.removeHandler()
            throw GlobalShortcutError.registerFailed(registerStatus)
        }
    }

    /// Carbon 句柄本身不具备 Sendable 标记，集中到只在主线程写入的资源盒中。
    private final class Resources: @unchecked Sendable {
        var hotKey: EventHotKeyRef?
        var eventHandler: EventHandlerRef?

        func removeHandler() {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
        }

        deinit {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            if let eventHandler { RemoveEventHandler(eventHandler) }
        }
    }
}

import Carbon.HIToolbox
import Combine
import Foundation
import WooTodoCore

@MainActor
final class ShortcutSettingsStore: ObservableObject {
    private static let defaultsKey = "shortcuts.global.v1"

    static let defaultBindings: [GlobalShortcutCommand: GlobalShortcutBinding] = [
        .quickAdd: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_1),
            modifiers: [.shift, .option],
            keyLabel: "1"
        ),
        .toggleTaskPanel: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: [.shift, .option],
            keyLabel: "2"
        ),
        .toggleAlwaysOnTop: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_3),
            modifiers: [.shift, .option],
            keyLabel: "3"
        ),
        .toggleClickThrough: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: [.shift, .option],
            keyLabel: "4"
        ),
        .increasePanelOpacity: GlobalShortcutBinding(
            keyCode: UInt32(kVK_UpArrow),
            modifiers: [.shift, .option],
            keyLabel: "↑"
        ),
        .decreasePanelOpacity: GlobalShortcutBinding(
            keyCode: UInt32(kVK_DownArrow),
            modifiers: [.shift, .option],
            keyLabel: "↓"
        ),
    ]

    private static let legacyDefaultBindings: [GlobalShortcutCommand: GlobalShortcutBinding] = [
        .quickAdd: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: [.shift, .option],
            keyLabel: "N"
        ),
        .toggleTaskPanel: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: [.shift, .option],
            keyLabel: "L"
        ),
        .toggleAlwaysOnTop: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: [.shift, .option],
            keyLabel: "T"
        ),
        .toggleClickThrough: GlobalShortcutBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: [.control, .option],
            keyLabel: "Space"
        ),
        .increasePanelOpacity: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_5),
            modifiers: [.shift, .option],
            keyLabel: "5"
        ),
        .decreasePanelOpacity: GlobalShortcutBinding(
            keyCode: UInt32(kVK_ANSI_6),
            modifiers: [.shift, .option],
            keyLabel: "6"
        ),
    ]

    @Published private(set) var bindings: [GlobalShortcutCommand: GlobalShortcutBinding]
    @Published private(set) var errorMessage: String?

    var onBindingsChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let actions: [GlobalShortcutCommand: () -> Void]
    private var registrations: [GlobalShortcutCommand: GlobalShortcut] = [:]

    init(
        defaults: UserDefaults = .standard,
        actions: [GlobalShortcutCommand: () -> Void]
    ) {
        self.defaults = defaults
        self.actions = actions
        self.bindings = Self.loadBindings(from: defaults)
    }

    func start() {
        registrations.removeAll()
        errorMessage = nil
        for command in GlobalShortcutCommand.allCases {
            guard let binding = bindings[command] else { continue }
            do {
                registrations[command] = try makeRegistration(
                    command: command,
                    binding: binding
                )
            } catch {
                errorMessage = "\(command.title)：\(error.localizedDescription)"
            }
        }
        onBindingsChanged?()
    }

    func binding(for command: GlobalShortcutCommand) -> GlobalShortcutBinding {
        bindings[command] ?? Self.defaultBindings[command]!
    }

    func update(
        _ command: GlobalShortcutCommand,
        binding: GlobalShortcutBinding
    ) {
        var candidate = bindings
        candidate[command] = binding
        do {
            try GlobalShortcutConfiguration.validate(candidate)
            let registration = try makeRegistration(command: command, binding: binding)
            registrations[command] = registration
            bindings = candidate
            try persist()
            errorMessage = nil
            onBindingsChanged?()
        } catch {
            errorMessage = "\(command.title)：\(error.localizedDescription)"
        }
    }

    func reset(_ command: GlobalShortcutCommand) {
        guard let binding = Self.defaultBindings[command] else { return }
        update(command, binding: binding)
    }

    func resetAll() {
        registrations.removeAll()
        bindings = Self.defaultBindings
        do {
            try persist()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        start()
    }

    func clearError() {
        errorMessage = nil
    }

    private func makeRegistration(
        command: GlobalShortcutCommand,
        binding: GlobalShortcutBinding
    ) throws -> GlobalShortcut {
        guard let action = actions[command] else {
            throw ShortcutSettingsError.missingAction(command)
        }
        return try GlobalShortcut(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers.carbonValue,
            action: action
        )
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(bindings)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func loadBindings(
        from defaults: UserDefaults
    ) -> [GlobalShortcutCommand: GlobalShortcutBinding] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                  [GlobalShortcutCommand: GlobalShortcutBinding].self,
                  from: data
              ),
              (try? GlobalShortcutConfiguration.validate(decoded)) != nil else {
            return defaultBindings
        }
        // 逐项迁移旧默认值并补入新增命令，用户自定义过的组合保持不变。
        let migrated = GlobalShortcutConfiguration.migratingUnchangedDefaults(
            decoded,
            from: legacyDefaultBindings,
            to: defaultBindings
        )
        guard Set(migrated.keys) == Set(GlobalShortcutCommand.allCases),
              (try? GlobalShortcutConfiguration.validate(migrated)) != nil else {
            return defaultBindings
        }
        if migrated != decoded, let migratedData = try? JSONEncoder().encode(migrated) {
            defaults.set(migratedData, forKey: defaultsKey)
        }
        return migrated
    }
}

private enum ShortcutSettingsError: LocalizedError {
    case missingAction(GlobalShortcutCommand)

    var errorDescription: String? {
        switch self {
        case .missingAction(let command):
            "没有注册 \(command.title) 的执行动作"
        }
    }
}

extension GlobalShortcutCommand {
    var title: String {
        switch self {
        case .quickAdd: "快速新增任务"
        case .toggleTaskPanel: "显示或隐藏任务板"
        case .toggleAlwaysOnTop: "切换始终置顶"
        case .toggleClickThrough: "切换鼠标穿透"
        case .increasePanelOpacity: "增加不透明度"
        case .decreasePanelOpacity: "减少不透明度"
        }
    }

    var systemImage: String {
        switch self {
        case .quickAdd: "plus"
        case .toggleTaskPanel: "rectangle.on.rectangle"
        case .toggleAlwaysOnTop: "pin"
        case .toggleClickThrough: "cursorarrow.motionlines"
        case .increasePanelOpacity: "sun.max"
        case .decreasePanelOpacity: "sun.min"
        }
    }
}

private extension GlobalShortcutModifiers {
    var carbonValue: UInt32 {
        var value: UInt32 = 0
        if contains(.shift) { value |= UInt32(shiftKey) }
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.command) { value |= UInt32(cmdKey) }
        return value
    }
}

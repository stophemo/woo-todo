import Foundation

public enum GlobalShortcutCommand: String, CaseIterable, Codable, Sendable {
    case quickAdd
    case toggleTaskPanel
    case toggleAlwaysOnTop
    case toggleClickThrough
}

public struct GlobalShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
}

public struct GlobalShortcutBinding: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: GlobalShortcutModifiers
    public let keyLabel: String

    public init(
        keyCode: UInt32,
        modifiers: GlobalShortcutModifiers,
        keyLabel: String
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var displayValue: String {
        var value = ""
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + keyLabel
    }

    public func validate() throws {
        guard !modifiers.isEmpty else {
            throw GlobalShortcutConfigurationError.missingModifier
        }
        guard !keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GlobalShortcutConfigurationError.missingKey
        }
    }
}

public enum GlobalShortcutConfigurationError: Error, Equatable, LocalizedError {
    case missingModifier
    case missingKey
    case duplicate(
        command: GlobalShortcutCommand,
        conflictsWith: GlobalShortcutCommand
    )

    public var errorDescription: String? {
        switch self {
        case .missingModifier:
            "全局快捷键至少需要一个修饰键"
        case .missingKey:
            "全局快捷键缺少主按键"
        case .duplicate:
            "该组合已分配给其他 Woo Todo 操作"
        }
    }
}

public enum GlobalShortcutConfiguration {
    public static func validate(
        _ bindings: [GlobalShortcutCommand: GlobalShortcutBinding]
    ) throws {
        struct Chord: Hashable {
            let keyCode: UInt32
            let modifiers: GlobalShortcutModifiers
        }
        var owners: [Chord: GlobalShortcutCommand] = [:]
        for command in GlobalShortcutCommand.allCases {
            guard let binding = bindings[command] else { continue }
            try binding.validate()
            let chord = Chord(keyCode: binding.keyCode, modifiers: binding.modifiers)
            if let owner = owners[chord] {
                throw GlobalShortcutConfigurationError.duplicate(
                    command: command,
                    conflictsWith: owner
                )
            }
            owners[chord] = command
        }
    }

    public static func migratingUnchangedDefaults(
        _ bindings: [GlobalShortcutCommand: GlobalShortcutBinding],
        from legacyDefaults: [GlobalShortcutCommand: GlobalShortcutBinding],
        to currentDefaults: [GlobalShortcutCommand: GlobalShortcutBinding]
    ) -> [GlobalShortcutCommand: GlobalShortcutBinding] {
        var migrated = bindings
        for command in GlobalShortcutCommand.allCases {
            guard bindings[command] == legacyDefaults[command],
                  let replacement = currentDefaults[command] else {
                continue
            }
            var candidate = migrated
            candidate[command] = replacement
            if (try? validate(candidate)) != nil {
                migrated = candidate
            }
        }
        return migrated
    }
}

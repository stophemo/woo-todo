import Foundation
import Testing
@testable import WooTodoCore

struct GlobalShortcutConfigurationTests {
    @Test func displayValueUsesStableModifierOrderForNumberedShortcut() {
        let binding = GlobalShortcutBinding(
            keyCode: 18,
            modifiers: [.shift, .option],
            keyLabel: "1"
        )

        #expect(binding.displayValue == "⇧⌥1")
    }

    @Test func rejectsShortcutWithoutModifier() {
        let binding = GlobalShortcutBinding(
            keyCode: 45,
            modifiers: [],
            keyLabel: "N"
        )

        #expect(throws: GlobalShortcutConfigurationError.missingModifier) {
            try binding.validate()
        }
    }

    @Test func rejectsDuplicateBindings() {
        let binding = GlobalShortcutBinding(
            keyCode: 45,
            modifiers: [.shift, .option],
            keyLabel: "N"
        )

        #expect(throws: GlobalShortcutConfigurationError.self) {
            try GlobalShortcutConfiguration.validate([
                .quickAdd: binding,
                .toggleTaskPanel: binding,
            ])
        }
    }

    @Test func duplicateDetectionUsesPhysicalKeyRatherThanDisplayLabel() {
        #expect(throws: GlobalShortcutConfigurationError.self) {
            try GlobalShortcutConfiguration.validate([
                .quickAdd: GlobalShortcutBinding(
                    keyCode: 45,
                    modifiers: [.shift, .option],
                    keyLabel: "N"
                ),
                .toggleTaskPanel: GlobalShortcutBinding(
                    keyCode: 45,
                    modifiers: [.shift, .option],
                    keyLabel: "n"
                ),
            ])
        }
    }

    @Test func roundTripsPersistedBindings() throws {
        let expected: [GlobalShortcutCommand: GlobalShortcutBinding] = [
            .quickAdd: GlobalShortcutBinding(
                keyCode: 45,
                modifiers: [.shift, .option],
                keyLabel: "N"
            ),
        ]

        let encoded = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(
            [GlobalShortcutCommand: GlobalShortcutBinding].self,
            from: encoded
        )

        #expect(decoded == expected)
    }

    @Test func migratesOnlyBindingsThatStillMatchLegacyDefaults() {
        let legacy = defaults(labels: ["N", "L", "T", "Space"], keyCodes: [45, 37, 17, 49])
        let current = defaults(labels: ["1", "2", "3", "4"], keyCodes: [18, 19, 20, 21])
        var persisted = legacy
        persisted[.quickAdd] = GlobalShortcutBinding(
            keyCode: 6,
            modifiers: [.command, .option],
            keyLabel: "Z"
        )

        let migrated = GlobalShortcutConfiguration.migratingUnchangedDefaults(
            persisted,
            from: legacy,
            to: current
        )

        #expect(migrated[.quickAdd] == persisted[.quickAdd])
        #expect(migrated[.toggleTaskPanel] == current[.toggleTaskPanel])
        #expect(migrated[.toggleAlwaysOnTop] == current[.toggleAlwaysOnTop])
        #expect(migrated[.toggleClickThrough] == current[.toggleClickThrough])
    }

    @Test func keepsLegacyBindingWhenItsReplacementConflictsWithCustomization() throws {
        let legacy = defaults(labels: ["N", "L", "T", "Space"], keyCodes: [45, 37, 17, 49])
        let current = defaults(labels: ["1", "2", "3", "4"], keyCodes: [18, 19, 20, 21])
        var persisted = legacy
        persisted[.quickAdd] = current[.toggleTaskPanel]

        let migrated = GlobalShortcutConfiguration.migratingUnchangedDefaults(
            persisted,
            from: legacy,
            to: current
        )

        #expect(migrated[.quickAdd] == current[.toggleTaskPanel])
        #expect(migrated[.toggleTaskPanel] == legacy[.toggleTaskPanel])
        try GlobalShortcutConfiguration.validate(migrated)
    }

    private func defaults(
        labels: [String],
        keyCodes: [UInt32]
    ) -> [GlobalShortcutCommand: GlobalShortcutBinding] {
        let commands = GlobalShortcutCommand.allCases
        return Dictionary(uniqueKeysWithValues: commands.indices.map { index in
            let modifiers: GlobalShortcutModifiers = index == 3 && labels[index] == "Space"
                ? [.control, .option]
                : [.shift, .option]
            return (
                commands[index],
                GlobalShortcutBinding(
                    keyCode: keyCodes[index],
                    modifiers: modifiers,
                    keyLabel: labels[index]
                )
            )
        })
    }
}

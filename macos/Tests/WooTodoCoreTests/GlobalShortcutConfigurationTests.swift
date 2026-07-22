import Foundation
import Testing
@testable import WooTodoCore

struct GlobalShortcutConfigurationTests {
    @Test func displayValueUsesStableModifierOrder() {
        let binding = GlobalShortcutBinding(
            keyCode: 45,
            modifiers: [.shift, .option],
            keyLabel: "N"
        )

        #expect(binding.displayValue == "⇧⌥N")
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
}

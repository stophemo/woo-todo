import AppKit
import Testing
import WooTodoCore
@testable import WooTodoMacApp

struct FloatingPanelOpacityTests {
    @Test func shortcutAdjustsOpacityByTenPercent() {
        #expect(PanelOpacityPolicy.adjusted(0.5, by: PanelOpacityPolicy.adjustmentStep) == 0.6)
        #expect(PanelOpacityPolicy.adjusted(0.5, by: -PanelOpacityPolicy.adjustmentStep) == 0.4)
    }

    @Test func repeatedIncreaseIsIdempotentAtMaximum() {
        let once = PanelOpacityPolicy.adjusted(1, by: PanelOpacityPolicy.adjustmentStep)
        let twice = PanelOpacityPolicy.adjusted(once, by: PanelOpacityPolicy.adjustmentStep)

        #expect(once == 1)
        #expect(twice == once)
    }

    @Test func repeatedDecreaseIsIdempotentAtMinimum() {
        let once = PanelOpacityPolicy.adjusted(0.2, by: -PanelOpacityPolicy.adjustmentStep)
        let twice = PanelOpacityPolicy.adjusted(once, by: -PanelOpacityPolicy.adjustmentStep)

        #expect(once == 0.2)
        #expect(twice == once)
    }

    @Test func desktopWidgetTakesPrecedenceOverWindowLevels() {
        #expect(PanelPresentationPolicy.resolve(
            isDesktopWidget: true,
            isAlwaysOnTop: true
        ) == .desktopWidget)
    }

    @Test func disabledDesktopWidgetUsesRequestedWindowLevel() {
        #expect(PanelPresentationPolicy.resolve(
            isDesktopWidget: false,
            isAlwaysOnTop: false
        ) == .normal)
        #expect(PanelPresentationPolicy.resolve(
            isDesktopWidget: false,
            isAlwaysOnTop: true
        ) == .alwaysOnTop)
    }

    @MainActor @Test func defaultShortcutsReserveThreeFourAndFiveForPanelModes() {
        let defaults = ShortcutSettingsStore.defaultBindings
        #expect(defaults[.toggleClickThrough]?.displayValue == "⇧⌥3")
        #expect(defaults[.toggleAlwaysOnTop]?.displayValue == "⇧⌥4")
        #expect(defaults[.toggleDesktopWidget]?.displayValue == "⇧⌥5")
    }

    @Test func widgetResizeKeepsOriginAndHonorsMinimumSize() {
        let resized = PanelResizePolicy.resizedFrame(
            initialFrame: NSRect(x: 40, y: 50, width: 420, height: 520),
            mouseDelta: NSPoint(x: -200, y: -300),
            minimumSize: NSSize(width: 300, height: 360)
        )

        #expect(resized.origin == NSPoint(x: 40, y: 50))
        #expect(resized.size == NSSize(width: 300, height: 360))
    }

    @Test func legacyDefaultPanelSizeIsRecognizedWithoutMatchingCustomSizes() {
        #expect(PanelFramePolicy.usesLegacyDefaultSize(NSSize(width: 360, height: 520)))
        #expect(!PanelFramePolicy.usesLegacyDefaultSize(NSSize(width: 420, height: 520)))
        #expect(!PanelFramePolicy.usesLegacyDefaultSize(NSSize(width: 360, height: 480)))
    }

    @Test func panelFrameMigrationPreservesTopRightPositionWithinVisibleScreen() {
        let migrated = PanelFramePolicy.migratedFrame(
            from: NSRect(x: 1012, y: 383, width: 360, height: 520),
            visibleFrame: NSRect(x: 0, y: 0, width: 1470, height: 923)
        )

        #expect(migrated == NSRect(x: 762, y: 463, width: 610, height: 440))
    }

    @Test func panelFrameMigrationClampsExpandedPanelToVisibleScreen() {
        let migrated = PanelFramePolicy.migratedFrame(
            from: NSRect(x: 10, y: 20, width: 360, height: 520),
            visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(migrated == NSRect(x: 0, y: 100, width: 610, height: 440))
    }
}

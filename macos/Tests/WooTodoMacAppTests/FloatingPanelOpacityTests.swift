import Testing
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
}

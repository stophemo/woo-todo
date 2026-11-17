import AppKit

@main
enum WooTodoMacMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        if environment["WOO_TODO_UI_TEST"] == "1" {
            switch environment["WOO_TODO_UI_TEST_APPEARANCE"] {
            case "light": application.appearance = NSAppearance(named: .aqua)
            case "dark": application.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

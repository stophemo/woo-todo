import Foundation
import Testing
import WooTodoCore
@testable import WooTodoMacApp

@Suite("UI 测试屏幕映射")
struct AppRuntimeConfigurationTests {
    @Test("面板、主窗口与设置分区的旧名称仍然可用")
    func mapsScreenNames() throws {
        #expect(try AppRuntimeConfiguration.initialScreen(for: "panel") == .panel)
        #expect(try AppRuntimeConfiguration.initialScreen(for: "quick-add") == .quickAdd)
        #expect(try AppRuntimeConfiguration.initialScreen(for: "main") == .main(.today))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "tasks") == .main(.all))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "today") == .main(.today))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "all") == .main(.all))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "history") == .main(.history))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "statistics") == .main(.statistics))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "trash") == .main(.trash))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "display") == .settings(.display))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "shortcuts") == .settings(.shortcuts))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "sync") == .settings(.sync))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "mcp") == .settings(.mcp))
        #expect(try AppRuntimeConfiguration.initialScreen(for: "localData") == .settings(.localData))
    }

    @Test("未知屏幕名称直接报错")
    func rejectsUnknownScreen() {
        #expect(throws: (any Error).self) {
            _ = try AppRuntimeConfiguration.initialScreen(for: "unknown")
        }
    }

    @Test("构建期 WooTodoSyncEndpoint 只接受合法 HTTPS 根地址")
    func resolvesBundledSyncEndpoint() {
        #expect(AppRuntimeConfiguration.resolveDefaultSyncEndpoint(
            infoDictionary: [:]
        ) == nil)
        #expect(AppRuntimeConfiguration.resolveDefaultSyncEndpoint(
            infoDictionary: ["WooTodoSyncEndpoint": "   "]
        ) == nil)
        #expect(AppRuntimeConfiguration.resolveDefaultSyncEndpoint(
            infoDictionary: ["WooTodoSyncEndpoint": "http://sync.example.test"]
        ) == nil)
        #expect(AppRuntimeConfiguration.resolveDefaultSyncEndpoint(
            infoDictionary: ["WooTodoSyncEndpoint": "https://192.168.1.2"]
        ) == nil)
        #expect(AppRuntimeConfiguration.resolveDefaultSyncEndpoint(
            infoDictionary: ["WooTodoSyncEndpoint": " https://sync.example.test "]
        ) == URL(string: "https://sync.example.test"))
    }
}

struct WindowActivationPolicyTests {
    @Test func visibleWindowShowsDockIcon() {
        #expect(
            WindowActivationPolicy.resolve(mainVisible: true, settingsVisible: false)
                == .regular
        )
        #expect(
            WindowActivationPolicy.resolve(mainVisible: false, settingsVisible: true)
                == .regular
        )
        #expect(
            WindowActivationPolicy.resolve(mainVisible: false, settingsVisible: false)
                == .accessory
        )
    }
}

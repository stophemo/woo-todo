import SwiftUI
import WooTodoCore

enum WooTodoTheme {
    static let ink = Color(red: 23 / 255, green: 24 / 255, blue: 23 / 255)
    static let inkSoft = Color(red: 37 / 255, green: 39 / 255, blue: 37 / 255)
    static let paperBright = Color(red: 250 / 255, green: 251 / 255, blue: 248 / 255)
    static let mutedOnDark = Color(red: 174 / 255, green: 178 / 255, blue: 172 / 255)
    static let taskOnDark = Color(red: 240 / 255, green: 242 / 255, blue: 238 / 255)
    static let settledOnDark = Color(red: 133 / 255, green: 137 / 255, blue: 132 / 255)
    static let metadataOnDark = Color(red: 129 / 255, green: 133 / 255, blue: 127 / 255)
    static let controlBorderOnDark = Color(red: 116 / 255, green: 120 / 255, blue: 114 / 255)
    static let purple = Color(red: 107 / 255, green: 86 / 255, blue: 200 / 255)
    static let purpleLight = Color(red: 169 / 255, green: 154 / 255, blue: 232 / 255)
    static let green = Color(red: 56 / 255, green: 184 / 255, blue: 120 / 255)
    static let orange = Color(red: 237 / 255, green: 112 / 255, blue: 67 / 255)
    static let yellow = Color(red: 240 / 255, green: 200 / 255, blue: 90 / 255)
    static let lineOnDark = Color.white.opacity(0.09)
    static let taskLineOnDark = Color.white.opacity(0.07)
}

extension QuestTier {
    var accentColor: Color {
        switch self {
        case .mainline: WooTodoTheme.purple
        case .side: WooTodoTheme.green
        case .extra: WooTodoTheme.orange
        }
    }
}

import AppKit
import SwiftUI

/// 六位配对码输入：隐藏的 TextField 负责键盘、粘贴与回车，六个格子负责视觉呈现。
struct SixDigitCodeField: View {
    @Binding var code: String
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SixDigitCodeCells(
                code: code,
                activeIndex: isFocused ? min(code.count, 5) : nil
            )
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .onChange(of: code) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value {
                        code = digits
                    }
                }
                .onSubmit(onSubmit)
                .accessibilityLabel("六位配对码")
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .accessibilityElement(children: .contain)
    }
}

/// 只读的六位码展示，用于配对码与核对码。
struct SixDigitCodeDisplay: View {
    let code: String

    var body: some View {
        SixDigitCodeCells(code: code, activeIndex: nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("六位码 \(code)")
    }
}

private struct SixDigitCodeCells: View {
    let code: String
    let activeIndex: Int?

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? WooTodoTheme.purpleLight : WooTodoTheme.purple
    }

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<6, id: \.self) { index in
                cell(at: index)
            }
        }
    }

    private func cell(at index: Int) -> some View {
        let characters = Array(code)
        let digit = index < characters.count ? String(characters[index]) : ""
        let isActive = activeIndex == index
        return Text(digit.isEmpty ? "·" : digit)
            .font(.system(size: 27, weight: .semibold, design: .monospaced))
            .foregroundStyle(
                digit.isEmpty
                    ? Color.secondary.opacity(0.32)
                    : Color.primary
            )
            .frame(width: 46, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? accent
                            : Color.primary.opacity(digit.isEmpty ? 0.12 : 0.20),
                        lineWidth: isActive ? 1.6 : 1
                    )
            )
            .scaleEffect(isActive ? 1.035 : 1)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

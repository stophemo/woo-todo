import SwiftUI

struct DayCounterSettingsView: View {
    @ObservedObject var store: DayCounterStore
    @State private var isEnabled: Bool
    @State private var title: String
    @State private var startDate: Date

    init(store: DayCounterStore) {
        self.store = store
        _isEnabled = State(initialValue: store.configuration.isEnabled)
        _title = State(initialValue: store.configuration.title)
        _startDate = State(initialValue: store.configuration.startDate)
    }

    var body: some View {
        Form {
            Section("顶部副标题") {
                Toggle("显示纪念日计数", isOn: $isEnabled)
                TextField("例如：来到西安 remake", text: $title)
                    .disabled(!isEnabled)
                DatePicker(
                    "起始日期",
                    selection: $startDate,
                    displayedComponents: .date
                )
                .disabled(!isEnabled)
                Text("示例：来到西安 remake · 第 100 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("保存") {
                    store.update(isEnabled: isEnabled, title: title, startDate: startDate)
                    isEnabled = store.configuration.isEnabled
                    title = store.configuration.title
                }
                Button("隐藏副标题") {
                    store.disable()
                    isEnabled = false
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onChange(of: store.configuration) { _, value in
            isEnabled = value.isEnabled
            title = value.title
            startDate = value.startDate
        }
    }
}

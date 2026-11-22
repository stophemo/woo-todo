import SwiftUI

struct ReminderSettingsView: View {
    @ObservedObject var digestStore: DailyDigestSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每日晚间提醒")
                        .font(.title2.weight(.semibold))
                    Text("在固定时间汇总明天要做的任务，只发一条通知。任务本身的提醒仍按每条任务设置的时间触发。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("启用每日晚间提醒", isOn: $digestStore.isEnabled)
                        DatePicker(
                            "提醒时间",
                            selection: $digestStore.time,
                            displayedComponents: .hourAndMinute
                        )
                        .disabled(!digestStore.isEnabled)
                        Text("到点后会提示明天有哪些待办；没有安排时会提示明天暂时空闲。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

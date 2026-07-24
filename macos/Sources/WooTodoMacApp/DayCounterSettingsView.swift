import SwiftUI
import WooTodoCore

struct DayCounterSettingsView: View {
    private struct TemplateVariable: Identifiable, Sendable {
        let title: String
        let token: String

        var id: String { token }
    }

    private static let weekdayVariables = [
        TemplateVariable(title: "星期几", token: DayCounterConfiguration.weekdayToken),
        TemplateVariable(title: "星期简称", token: DayCounterConfiguration.weekdayShortToken),
        TemplateVariable(title: "英文星期几", token: DayCounterConfiguration.weekdayEnToken),
        TemplateVariable(title: "英文星期简称", token: DayCounterConfiguration.weekdayEnShortToken)
    ]
    private static let dateVariables = [
        TemplateVariable(title: "日期", token: DayCounterConfiguration.dateToken),
        TemplateVariable(title: "中文日期", token: DayCounterConfiguration.dateLongToken),
        TemplateVariable(title: "年份", token: DayCounterConfiguration.yearToken),
        TemplateVariable(title: "月份", token: DayCounterConfiguration.monthToken),
        TemplateVariable(title: "两位月份", token: DayCounterConfiguration.monthPaddedToken),
        TemplateVariable(title: "日", token: DayCounterConfiguration.dayToken),
        TemplateVariable(title: "两位日", token: DayCounterConfiguration.dayPaddedToken),
        TemplateVariable(title: "起始日期", token: DayCounterConfiguration.startDateToken),
        TemplateVariable(title: "截止日期", token: DayCounterConfiguration.deadlineDateToken)
    ]
    private static let counterVariables = [
        TemplateVariable(title: "耗时天数", token: DayCounterConfiguration.elapsedDaysToken),
        TemplateVariable(title: "截止天数", token: DayCounterConfiguration.deadlineDaysToken),
        TemplateVariable(title: "耗时（月+天）", token: DayCounterConfiguration.elapsedMonthsDaysToken),
        TemplateVariable(title: "截止（月+天）", token: DayCounterConfiguration.deadlineMonthsDaysToken)
    ]

    @ObservedObject var store: DayCounterStore
    @State private var headerTemplate: String
    @State private var subtitleTemplate: String
    @State private var startDate: Date
    @State private var deadlineDate: Date
    @State private var headerSelection: TextSelection?
    @State private var subtitleSelection: TextSelection?

    init(store: DayCounterStore) {
        self.store = store
        _headerTemplate = State(initialValue: store.configuration.headerTemplate)
        _subtitleTemplate = State(initialValue: store.configuration.subtitleTemplate)
        _startDate = State(initialValue: store.configuration.startDate)
        _deadlineDate = State(initialValue: store.configuration.deadlineDate)
    }

    var body: some View {
        Form {
            Section("标题模板") {
                templateField(
                    accessibilityLabel: "标题模板内容",
                    placeholder: "今日任务",
                    value: $headerTemplate,
                    selection: $headerSelection,
                    limit: 80
                )
            }

            Section("副标题模板") {
                templateField(
                    accessibilityLabel: "副标题模板内容",
                    placeholder: "留空则隐藏副标题",
                    value: $subtitleTemplate,
                    selection: $subtitleSelection,
                    limit: 160
                )
            }

            Section("变量日期") {
                DatePicker("起始日期", selection: $startDate, displayedComponents: .date)
                DatePicker("截止日期", selection: $deadlineDate, displayedComponents: .date)
            }

            Section("实时预览") {
                VStack(alignment: .leading, spacing: 4) {
                    if let header = preview.headerText(on: store.renderDate) {
                        Text(header)
                            .font(.title3.weight(.semibold))
                    }
                    if let subtitle = preview.subtitleText(on: store.renderDate) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if preview.headerText(on: store.renderDate) == nil &&
                        preview.subtitleText(on: store.renderDate) == nil {
                        Text("顶部文字已隐藏")
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(2)
            }

            Section {
                Button {
                    store.update(
                        headerTemplate: headerTemplate,
                        subtitleTemplate: subtitleTemplate,
                        startDate: startDate,
                        deadlineDate: deadlineDate
                    )
                    load(store.configuration)
                } label: {
                    Label("保存显示设置", systemImage: "checkmark")
                }
                Button {
                    store.restoreDefaults()
                    load(store.configuration)
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onChange(of: store.configuration) { _, value in
            load(value)
        }
    }

    private var preview: DayCounterConfiguration {
        DayCounterConfiguration(
            headerTemplate: headerTemplate,
            subtitleTemplate: subtitleTemplate,
            startDate: startDate,
            deadlineDate: deadlineDate
        )
    }

    @ViewBuilder
    private func templateField(
        accessibilityLabel: String,
        placeholder: String,
        value: Binding<String>,
        selection: Binding<TextSelection?>,
        limit: Int
    ) -> some View {
        HStack(spacing: 10) {
            TextField("", text: value, selection: selection, prompt: Text(placeholder))
                .labelsHidden()
                .accessibilityLabel(accessibilityLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .onChange(of: value.wrappedValue) { _, updated in
                    guard updated.count > limit else { return }
                    value.wrappedValue = String(updated.prefix(limit))
                    selection.wrappedValue = TextSelection(
                        insertionPoint: value.wrappedValue.endIndex
                    )
                }
            Text("\(value.wrappedValue.count)/\(limit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                Section("星期") {
                    variableButtons(
                        Self.weekdayVariables,
                        value: value,
                        selection: selection,
                        limit: limit
                    )
                }
                Section("日期") {
                    variableButtons(
                        Self.dateVariables,
                        value: value,
                        selection: selection,
                        limit: limit
                    )
                }
                Section("计时") {
                    variableButtons(
                        Self.counterVariables,
                        value: value,
                        selection: selection,
                        limit: limit
                    )
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("插入动态变量")
        }
    }

    @ViewBuilder
    private func variableButtons(
        _ variables: [TemplateVariable],
        value: Binding<String>,
        selection: Binding<TextSelection?>,
        limit: Int
    ) -> some View {
        ForEach(variables) { variable in
            Button("\(variable.title)  \(variable.token)") {
                insert(variable.token, into: value, selection: selection, limit: limit)
            }
        }
    }

    private func insert(
        _ token: String,
        into value: Binding<String>,
        selection: Binding<TextSelection?>,
        limit: Int
    ) {
        let source = value.wrappedValue
        let range: Range<String.Index>
        if let textSelection = selection.wrappedValue {
            switch textSelection.indices {
            case .selection(let selectedRange):
                range = selectedRange
            case .multiSelection:
                range = source.endIndex..<source.endIndex
            @unknown default:
                range = source.endIndex..<source.endIndex
            }
        } else {
            range = source.endIndex..<source.endIndex
        }
        let insertionOffset = source.distance(from: source.startIndex, to: range.lowerBound)
        var updated = source
        updated.replaceSubrange(range, with: token)
        guard updated.count <= limit else { return }
        value.wrappedValue = updated
        let insertionPoint = updated.index(
            updated.startIndex,
            offsetBy: insertionOffset + token.count
        )
        selection.wrappedValue = TextSelection(insertionPoint: insertionPoint)
    }

    private func load(_ configuration: DayCounterConfiguration) {
        headerTemplate = configuration.headerTemplate
        subtitleTemplate = configuration.subtitleTemplate
        startDate = configuration.startDate
        deadlineDate = configuration.deadlineDate
        headerSelection = nil
        subtitleSelection = nil
    }
}

import SwiftUI
import WooTodoCore

struct TaskCategorySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var categories: [TaskCategory]
    @State private var newName = ""
    @State private var errorMessage: String?
    @FocusState private var newNameFocused: Bool
    let focusNewName: Bool
    let save: ([TaskCategory]) -> Void

    init(
        categories: [TaskCategory],
        focusNewName: Bool = false,
        save: @escaping ([TaskCategory]) -> Void
    ) {
        _categories = State(initialValue: categories)
        self.focusNewName = focusNewName
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("管理标签")
                .font(.title2.weight(.semibold))
            Text("最多 8 个标签；从上到下优先级由高到低，优先级高的标签会排在任务列表更前面。删除标签时，该标签下的待办会归入未分类，历史记录保留原标签。")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($categories) { $category in
                    HStack(spacing: 10) {
                        VStack(spacing: 2) {
                            Button {
                                move(category.id, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .frame(width: 16, height: 13)
                            }
                            .buttonStyle(.borderless)
                            .disabled(index(of: category.id) == 0)
                            .help("上移（提高优先级）")
                            .accessibilityLabel("上移（提高优先级）")

                            Button {
                                move(category.id, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .frame(width: 16, height: 13)
                            }
                            .buttonStyle(.borderless)
                            .disabled(index(of: category.id) == categories.count - 1)
                            .help("下移（降低优先级）")
                            .accessibilityLabel("下移（降低优先级）")
                        }
                        TextField("标签名称", text: $category.name)
                            .textFieldStyle(.roundedBorder)
                        if category.id == TaskCategory.inboxID {
                            Text("无标签兜底")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button(role: .destructive) {
                                categories.removeAll { $0.id == category.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)

            HStack(spacing: 10) {
                TextField("新标签名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($newNameFocused)
                Button("添加") {
                    addCategory()
                }
                .disabled(
                    newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        categories.count >= TaskCategory.maximumCount
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            if focusNewName {
                DispatchQueue.main.async { newNameFocused = true }
            }
        }
    }

    private func index(of id: String) -> Int? {
        categories.firstIndex(where: { $0.id == id })
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = index(of: id) else { return }
        let target = index + offset
        guard categories.indices.contains(target) else { return }
        categories.swapAt(index, target)
    }

    private func addCategory() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard categories.count < TaskCategory.maximumCount else {
            errorMessage = "最多只能有 8 个标签"
            return
        }
        guard !categories.contains(where: { $0.name == name }) else {
            errorMessage = "已经有同名标签"
            return
        }
        let id = TaskCategory.newID(existing: Set(categories.map(\.id)))
        guard let category = try? TaskCategory(
            id: id,
            name: name,
            order: categories.count
        ) else {
            errorMessage = "标签名称需要 1–12 个字符"
            return
        }
        categories.append(category)
        newName = ""
        errorMessage = nil
    }

    private func commit() {
        let normalized = TaskCategory.normalizeList(categories)
        guard normalized.count == categories.count else {
            errorMessage = "标签名称需要 1–12 个字符，且不能重复"
            return
        }
        save(normalized)
        dismiss()
    }
}

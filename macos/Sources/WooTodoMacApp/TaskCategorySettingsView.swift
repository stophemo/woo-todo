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
            Text("管理类型")
                .font(.title2.weight(.semibold))
            Text("最多 8 个类型；删除类型时，该类型下的待办会归入未分类，历史记录保留原类型。")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($categories) { $category in
                    HStack(spacing: 10) {
                        TextField("类型名称", text: $category.name)
                            .textFieldStyle(.roundedBorder)
                        if category.id == TaskCategory.inboxID {
                            Text("兜底")
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
                TextField("新类型名称", text: $newName)
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

    private func addCategory() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard categories.count < TaskCategory.maximumCount else {
            errorMessage = "最多只能有 8 个类型"
            return
        }
        guard !categories.contains(where: { $0.name == name }) else {
            errorMessage = "已经有同名类型"
            return
        }
        let id = TaskCategory.newID(existing: Set(categories.map(\.id)))
        guard let category = try? TaskCategory(
            id: id,
            name: name,
            order: categories.count
        ) else {
            errorMessage = "类型名称需要 1–12 个字符"
            return
        }
        categories.append(category)
        newName = ""
        errorMessage = nil
    }

    private func commit() {
        let normalized = TaskCategory.normalizeList(categories)
        guard normalized.count == categories.count else {
            errorMessage = "类型名称需要 1–12 个字符，且不能重复"
            return
        }
        save(normalized)
        dismiss()
    }
}

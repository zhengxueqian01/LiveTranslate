import SwiftUI

struct LanguagePickerItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

enum LanguagePickerFilter {
    static func filter(_ items: [LanguagePickerItem], query: String) -> [LanguagePickerItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(value)
                || $0.id.localizedCaseInsensitiveContains(value)
        }
    }
}

struct LanguagePickerSelectionState: Equatable, Sendable {
    private(set) var draftSelection: String?
    private(set) var confirmedSelection: String?

    init(initialSelection: String?) {
        draftSelection = initialSelection
        confirmedSelection = initialSelection
    }

    mutating func select(_ identifier: String) {
        draftSelection = identifier
        confirmedSelection = identifier
    }

    mutating func confirm() -> String? {
        confirmedSelection = draftSelection
        return confirmedSelection
    }
}

struct LanguagePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let items: [LanguagePickerItem]
    @Binding private var selection: String?
    @State private var selectionState: LanguagePickerSelectionState
    @State private var query = ""

    init(
        title: String,
        items: [LanguagePickerItem],
        selection: Binding<String?>
    ) {
        self.title = title
        self.items = items
        _selection = selection
        _selectionState = State(
            initialValue: LanguagePickerSelectionState(
                initialSelection: selection.wrappedValue
            )
        )
    }

    var body: some View {
        List(LanguagePickerFilter.filter(items, query: query)) { item in
            Button {
                selectionState.select(item.id)
                selection = selectionState.confirmedSelection
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        if titleCounts[item.title, default: 0] > 1 {
                            Text(item.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if selectionState.draftSelection == item.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "搜索语言")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    guard let confirmedSelection = selectionState.confirm() else {
                        return
                    }
                    selection = confirmedSelection
                    dismiss()
                }
                .disabled(selectionState.draftSelection == nil)
            }
        }
    }

    private var titleCounts: [String: Int] {
        items.reduce(into: [:]) { counts, item in
            counts[item.title, default: 0] += 1
        }
    }
}

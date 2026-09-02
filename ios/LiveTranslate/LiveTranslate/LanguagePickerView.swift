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

struct LanguagePickerView: View {
    let title: String
    let items: [LanguagePickerItem]
    @Binding var selection: String?
    @State private var query = ""

    var body: some View {
        List(LanguagePickerFilter.filter(items, query: query)) { item in
            Button {
                selection = item.id
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
                    if selection == item.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "搜索语言")
    }

    private var titleCounts: [String: Int] {
        items.reduce(into: [:]) { counts, item in
            counts[item.title, default: 0] += 1
        }
    }
}

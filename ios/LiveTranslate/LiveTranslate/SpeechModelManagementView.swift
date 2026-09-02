import SwiftUI

struct SpeechModelManagementView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            Section("已保留的语音模型") {
                if viewModel.reservedSpeechLocaleIdentifiers.isEmpty {
                    Text("没有由本 App 保留的语音模型")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.reservedSpeechLocaleIdentifiers, id: \.self) { identifier in
                    LabeledContent(identifier) {
                        Button("释放", role: .destructive) {
                            Task { await viewModel.releaseSpeechLocale(identifier) }
                        }
                        .disabled(!viewModel.canReleaseSpeechModels)
                    }
                }
            }
            Section("翻译模型") {
                Text("翻译模型由 iOS 管理，需要在 iPhone 的系统翻译语言管理界面删除。")
            }
        }
        .navigationTitle("模型管理")
        .task { await viewModel.loadReservedSpeechLocales() }
    }
}

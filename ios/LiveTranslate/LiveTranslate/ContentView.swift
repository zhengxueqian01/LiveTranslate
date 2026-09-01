//
//  ContentView.swift
//  LiveTranslate
//
//  Created by Xueqian Zheng on 2026/9/1.
//

import SwiftUI
@preconcurrency import Translation

struct ContentView: View {
    @StateObject private var viewModel: AppViewModel
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var translationSourceLanguage: SourceLanguage = .english
    @State private var captionPiPController = CaptionPiPController()

    init(viewModel: AppViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? AppViewModel.live())
    }

    var body: some View {
        let sourceLanguage = translationSourceLanguage

        NavigationStack {
            Form {
                Section("输入语言") {
                    Picker("音频语言", selection: $viewModel.selectedLanguage) {
                        Text("英语").tag(SourceLanguage.english)
                        Text("日语").tag(SourceLanguage.japanese)
                    }
                    Text("目标语言：简体中文")
                        .foregroundStyle(.secondary)
                }

                Section("本地模型") {
                    LabeledContent("语音识别", value: speechStatusText)
                    LabeledContent(
                        "翻译",
                        value: viewModel.isTranslationReady ? "已准备" : "待准备"
                    )
                    if viewModel.speechStatus == .needsDownload {
                        Button("下载语音模型") {
                            Task { await viewModel.installSpeechModel() }
                        }
                    }
                }

                Section("字幕预览") {
                    Text(viewModel.latestSnapshot?.sourceText ?? "等待原文字幕")
                    Text(viewModel.latestSnapshot?.translatedText ?? "等待中文翻译")
                        .foregroundStyle(.secondary)
                    if captionPiPController.isSupported {
                        Button("打开画中画字幕") {
                            viewModel.startCaptionObservation()
                            captionPiPController.start()
                        }
                    }
                }

                Section("系统广播") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("开始读取 App 音频")
                            Text("iOS 会显示系统广播确认界面")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        BroadcastPickerView()
                            .frame(width: 52, height: 52)
                            .allowsHitTesting(viewModel.canStartBroadcast)
                            .opacity(viewModel.canStartBroadcast ? 1 : 0.35)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section("错误") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("实时字幕翻译")
            .task {
                viewModel.refreshCaption()
                viewModel.startCaptionObservation()
                await viewModel.refreshModelStatus()
                configureTranslation()
            }
            .onAppear {
                captionPiPController.didStop = {
                    viewModel.stopCaptionObservation()
                }
            }
            .onChange(of: viewModel.latestSnapshot) { _, snapshot in
                guard let snapshot else {
                    return
                }
                captionPiPController.render(snapshot)
            }
            .onDisappear {
                viewModel.stopCaptionObservation()
                captionPiPController.stop()
            }
            .onChange(of: viewModel.selectedLanguage) {
                viewModel.markTranslationNeedsPreparation()
                configureTranslation()
                Task { await viewModel.refreshModelStatus() }
            }
            .translationTask(translationConfiguration) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run {
                        viewModel.markTranslationReady(for: sourceLanguage)
                    }
                } catch {
                    await MainActor.run {
                        viewModel.reportTranslationError(error, for: sourceLanguage)
                    }
                }
            }
        }
    }

    private var speechStatusText: String {
        switch viewModel.speechStatus {
        case .unknown:
            "检查中"
        case .unsupported:
            "不支持"
        case .needsDownload:
            "需要下载"
        case .downloading:
            "下载中"
        case .installed:
            "已安装"
        }
    }

    private func configureTranslation() {
        let sourceLanguage = viewModel.selectedLanguage
        translationSourceLanguage = sourceLanguage
        if #available(iOS 26.4, *) {
            translationConfiguration = TranslationSession.Configuration(
                source: sourceLanguage.translationSource,
                target: SourceLanguage.translationTarget,
                preferredStrategy: .lowLatency
            )
        } else {
            translationConfiguration = TranslationSession.Configuration(
                source: sourceLanguage.translationSource,
                target: SourceLanguage.translationTarget
            )
        }
    }
}

#Preview {
    ContentView()
}

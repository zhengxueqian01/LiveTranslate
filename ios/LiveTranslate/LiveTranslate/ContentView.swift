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
    private let captionObservationLifecycle: CaptionPreviewObservationLifecycle
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var translationPreparation: TranslationPreparationRequest?
    @StateObject private var captionPiPController = CaptionPiPController()

    init(viewModel: AppViewModel? = nil) {
        let resolvedViewModel = viewModel ?? AppViewModel.live()
        _viewModel = StateObject(wrappedValue: resolvedViewModel)
        captionObservationLifecycle = CaptionPreviewObservationLifecycle(
            viewModel: resolvedViewModel
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("输入语言") {
                    NavigationLink {
                        LanguagePickerView(
                            title: "音频语言",
                            items: inputPickerItems,
                            selection: inputSelection
                        )
                    } label: {
                        selectionRow(
                            title: "音频语言",
                            value: viewModel.selectedInput?.displayName
                        )
                    }
                    .disabled(viewModel.inputLanguages.isEmpty)

                    NavigationLink {
                        LanguagePickerView(
                            title: "目标语言",
                            items: outputPickerItems,
                            selection: outputSelection
                        )
                    } label: {
                        selectionRow(
                            title: "目标语言",
                            value: viewModel.selectedOutput?.displayName
                        )
                    }
                    .disabled(viewModel.outputLanguages.isEmpty)

                    if viewModel.inputLanguages.isEmpty || viewModel.outputLanguages.isEmpty {
                        Text("正在读取系统支持的语言…")
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.languageCatalogErrorMessage != nil {
                        Button("重新加载语言") {
                            Task { await viewModel.loadLanguages() }
                        }
                    }
                }

                Section("本地模型") {
                    LabeledContent("语音识别", value: speechStatusText)
                    LabeledContent("翻译", value: translationStatusText)
                    NavigationLink("模型管理") {
                        SpeechModelManagementView(viewModel: viewModel)
                    }
                    if let preparationStatusText {
                        Text(preparationStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.currentConfiguration != nil, !viewModel.resourceState.isReady {
                        Button("下载所需模型") {
                            Task {
                                guard case .prepareTranslation(let request) = await viewModel.beginModelPreparation() else {
                                    return
                                }
                                let pair = request.configuration
                                translationPreparation = request
                                if #available(iOS 26.4, *) {
                                    translationConfiguration = TranslationSession.Configuration(
                                        source: Locale.Language(
                                            identifier: pair.sourceTranslationLanguageIdentifier
                                        ),
                                        target: Locale.Language(
                                            identifier: pair.targetTranslationLanguageIdentifier
                                        ),
                                        preferredStrategy: .lowLatency
                                    )
                                } else {
                                    translationConfiguration = TranslationSession.Configuration(
                                        source: Locale.Language(
                                            identifier: pair.sourceTranslationLanguageIdentifier
                                        ),
                                        target: Locale.Language(
                                            identifier: pair.targetTranslationLanguageIdentifier
                                        )
                                    )
                                }
                            }
                        }
                        .disabled(!canBeginModelPreparation)
                    }
                }

                Section("字幕预览") {
                    CaptionPiPHostViewRepresentable(hostView: captionPiPController.hostView)
                        .frame(maxWidth: .infinity)
                        .frame(height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(viewModel.latestSnapshot?.sourceText ?? "等待原文字幕")
                    Text(viewModel.latestSnapshot?.translatedText ?? "等待译文字幕")
                        .foregroundStyle(.secondary)
                    if captionPiPController.isReadyForPictureInPicture {
                        Button("打开画中画字幕") {
                            captionPiPController.start()
                            if let snapshot = viewModel.latestSnapshot {
                                captionPiPController.render(snapshot)
                            }
                        }
                        if let statusMessage = captionPiPController.startState.statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(
                                    captionPiPController.startState.isFailure
                                        ? Color.red
                                        : Color.secondary
                                )
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
                captionObservationLifecycle.pageDidAppear()
                await viewModel.loadLanguages()
            }
            .onAppear {
                captionPiPController.didStop = {
                    captionObservationLifecycle.pictureInPictureDidStop()
                }
            }
            .onChange(of: viewModel.latestSnapshot) { _, snapshot in
                guard let snapshot else {
                    return
                }
                captionPiPController.render(snapshot)
            }
            .onDisappear {
                captionObservationLifecycle.pageDidDisappear()
                captionPiPController.stop()
            }
            .translationTask(translationConfiguration) { session in
                guard let request = translationPreparation else { return }
                do {
                    try await session.prepareTranslation()
                    await viewModel.finishTranslationPreparation(for: request, error: nil)
                } catch {
                    await viewModel.finishTranslationPreparation(for: request, error: error)
                }
                translationPreparation = nil
                translationConfiguration = nil
            }
        }
    }

    private var inputPickerItems: [LanguagePickerItem] {
        viewModel.inputLanguages.map {
            LanguagePickerItem(id: $0.localeIdentifier, title: $0.displayName)
        }
    }

    private var outputPickerItems: [LanguagePickerItem] {
        viewModel.outputLanguages.map {
            LanguagePickerItem(id: $0.languageIdentifier, title: $0.displayName)
        }
    }

    private func selectionRow(title: String, value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? "未选择")
                .foregroundStyle(.secondary)
        }
    }

    private var inputSelection: Binding<String?> {
        Binding(
            get: { viewModel.selectedInput?.localeIdentifier },
            set: { identifier in
                guard let identifier else { return }
                Task { await viewModel.selectInput(identifier: identifier) }
            }
        )
    }

    private var outputSelection: Binding<String?> {
        Binding(
            get: { viewModel.selectedOutput?.languageIdentifier },
            set: { identifier in
                guard let identifier else { return }
                Task { await viewModel.selectOutput(identifier: identifier) }
            }
        )
    }

    private var canBeginModelPreparation: Bool {
        guard translationConfiguration == nil,
              viewModel.preparationPhase == .idle else {
            return false
        }
        let speech = viewModel.resourceState.speech.status
        let translation = viewModel.resourceState.translation
        return speech != .unknown
            && speech != .unsupported
            && speech != .downloading
            && translation != .unknown
            && translation != .unsupported
            && translation != .downloading
    }

    private var speechStatusText: String {
        let state = viewModel.resourceState.speech
        if state.status == .installed, !state.isReserved {
            return "已安装，待预留"
        }
        return resourceStatusText(state.status)
    }

    private var translationStatusText: String {
        resourceStatusText(viewModel.resourceState.translation)
    }

    private var preparationStatusText: String? {
        switch viewModel.preparationPhase {
        case .idle:
            nil
        case .preparingSpeech:
            "正在准备语音模型…"
        case .preparingTranslation:
            "正在准备翻译模型…"
        }
    }

    private func resourceStatusText(_ status: ModelResourceStatus) -> String {
        switch status {
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
        case .notRequired:
            "无需翻译"
        }
    }
}

#Preview {
    ContentView()
}

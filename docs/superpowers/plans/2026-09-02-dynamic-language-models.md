# LiveTranslate Dynamic Languages and On-Demand Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded English/Japanese-to-Chinese flow with system-discovered input and output languages whose resources are downloaded only after an explicit user action.

**Architecture:** Add versioned shared language configuration and two testable service boundaries: one discovers system languages and one manages resource status. The main App owns selection and explicit Translation preparation; the ReplayKit extension reads one immutable configuration and uses installed resources only.

**Tech Stack:** Swift 6, SwiftUI, Speech, Translation, ReplayKit, App Group `UserDefaults`, XCTest, Xcode 26.5, iOS 26.0.

**Spec:** `docs/superpowers/specs/2026-09-02-dynamic-language-models-design.md`

## Global Constraints

- “All languages” means every language returned by the current device's Speech and Translation frameworks.
- App launch, catalog loading, selection changes, and status refreshes must never download resources.
- Only “下载所需模型” may call `prepareTranslation()` or request Speech asset installation.
- The Broadcast Upload Extension must never download resources.
- Input equals output uses Speech plus pass-through text and needs no Translation model.
- Add no server, API key, third-party SDK, analytics, telemetry, or app-owned network call.
- Save no audio or translation history; retain one configuration and one latest caption snapshot.
- Preserve existing uncommitted AppIcon, caption latency, long-caption, and related test changes. Inspect diffs and stage only current-task hunks in already-dirty files.
- Existing synchronized Xcode groups automatically include new Swift files; do not edit `project.pbxproj` for file membership.
- Use simulator destination `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`; ReplayKit and real model operations still require iPhone verification.

## File Map

- Shared: create `LanguageConfiguration.swift` and `LanguageConfigurationStore.swift`; remove legacy language files after every consumer migrates.
- Main App: create `LanguageCatalogService.swift`, `LanguageResourceService.swift`, `LanguagePickerView.swift`, and `SpeechModelManagementView.swift`; update `AppViewModel.swift` and `ContentView.swift`.
- Broadcast: generalize `SpeechPipeline.swift`, `AppleTranslationClient.swift`, and `SampleHandler.swift`.
- Tests: replace hard-coded language tests and add catalog, resource, picker, management, and arbitrary-pair coverage.

---

### Task 1: Versioned Shared Configuration and Legacy Migration

**Files:**
- Create: `ios/LiveTranslate/Shared/LanguageConfiguration.swift`
- Create: `ios/LiveTranslate/Shared/LanguageConfigurationStore.swift`
- Modify: `ios/LiveTranslate/LiveTranslateTests/LanguageSelectionTests.swift`

**Interfaces:**
- Produces `SpeechLanguageOption`, `TranslationLanguageOption`, and `LanguagePairConfiguration`.
- Produces `LanguageConfigurationStoring.load()` and `save(_:)`.
- Keeps `SourceLanguage` and `SourceLanguageStore` temporarily so current consumers compile.

- [ ] **Step 1: Write failing configuration and migration tests**

```swift
func testConfigurationRoundTripsThroughSharedDefaults() {
    let defaults = isolatedDefaults()
    let store = LanguageConfigurationStore(defaults: defaults)
    let value = LanguagePairConfiguration(
        sourceSpeechLocaleIdentifier: "fr-FR",
        sourceTranslationLanguageIdentifier: "fr",
        targetTranslationLanguageIdentifier: "de"
    )
    store.save(value)
    XCTAssertEqual(store.load(), value)
}

func testLegacyJapaneseSelectionMigrates() {
    let defaults = isolatedDefaults()
    defaults.set("ja-JP", forKey: LanguageConfigurationStore.legacySourceKey)
    XCTAssertEqual(
        LanguageConfigurationStore(defaults: defaults).load(),
        LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "ja-JP",
            sourceTranslationLanguageIdentifier: "ja",
            targetTranslationLanguageIdentifier: "zh-Hans"
        )
    )
}

func testUnknownLegacySelectionDoesNotMigrate() {
    let defaults = isolatedDefaults()
    defaults.set("invalid", forKey: LanguageConfigurationStore.legacySourceKey)
    XCTAssertNil(LanguageConfigurationStore(defaults: defaults).load())
}
```

Add this helper to the test class:

```swift
private func isolatedDefaults() -> UserDefaults {
    let suiteName = "LanguageConfigurationStoreTests.\(UUID().uuidString)"
    addTeardownBlock {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    return UserDefaults(suiteName: suiteName)!
}
```

- [ ] **Step 2: Verify the tests fail because the new types do not exist**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguageSelectionTests
```

- [ ] **Step 3: Implement the shared value types**

```swift
struct SpeechLanguageOption: Codable, Hashable, Identifiable, Sendable {
    let localeIdentifier: String
    let translationLanguageIdentifier: String
    let displayName: String
    var id: String { localeIdentifier }
}

struct TranslationLanguageOption: Codable, Hashable, Identifiable, Sendable {
    let languageIdentifier: String
    let displayName: String
    var id: String { languageIdentifier }
}

struct LanguagePairConfiguration: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let sourceSpeechLocaleIdentifier: String
    let sourceTranslationLanguageIdentifier: String
    let targetTranslationLanguageIdentifier: String

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceSpeechLocaleIdentifier: String,
        sourceTranslationLanguageIdentifier: String,
        targetTranslationLanguageIdentifier: String
    ) {
        self.schemaVersion = schemaVersion
        self.sourceSpeechLocaleIdentifier = sourceSpeechLocaleIdentifier
        self.sourceTranslationLanguageIdentifier = sourceTranslationLanguageIdentifier
        self.targetTranslationLanguageIdentifier = targetTranslationLanguageIdentifier
    }

    var usesPassThroughTranslation: Bool {
        sourceTranslationLanguageIdentifier == targetTranslationLanguageIdentifier
    }
}
```

- [ ] **Step 4: Implement versioned persistence and exact legacy migration**

```swift
protocol LanguageConfigurationStoring: Sendable {
    func load() -> LanguagePairConfiguration?
    func save(_ configuration: LanguagePairConfiguration)
}

final class LanguageConfigurationStore: LanguageConfigurationStoring, @unchecked Sendable {
    static let configurationKey = "language.configuration.v1"
    static let legacySourceKey = "source.language"
    private let defaults: UserDefaults

    convenience init() throws {
        guard let defaults = UserDefaults(suiteName: CaptionStore.appGroupIdentifier) else {
            throw CaptionStoreError.appGroupUnavailable
        }
        self.init(defaults: defaults)
    }

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> LanguagePairConfiguration? {
        if let data = defaults.data(forKey: Self.configurationKey),
           let value = try? PropertyListDecoder().decode(LanguagePairConfiguration.self, from: data),
           value.schemaVersion == LanguagePairConfiguration.currentSchemaVersion {
            return value
        }
        guard let legacy = defaults.string(forKey: Self.legacySourceKey) else { return nil }
        let migrated: LanguagePairConfiguration?
        switch legacy {
        case "en-US":
            migrated = .init(sourceSpeechLocaleIdentifier: "en-US", sourceTranslationLanguageIdentifier: "en", targetTranslationLanguageIdentifier: "zh-Hans")
        case "ja-JP":
            migrated = .init(sourceSpeechLocaleIdentifier: "ja-JP", sourceTranslationLanguageIdentifier: "ja", targetTranslationLanguageIdentifier: "zh-Hans")
        default:
            migrated = nil
        }
        if let migrated { save(migrated) }
        return migrated
    }

    func save(_ configuration: LanguagePairConfiguration) {
        guard let data = try? PropertyListEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationKey)
    }
}
```

- [ ] **Step 5: Run focused tests and commit**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguageSelectionTests
git add ios/LiveTranslate/Shared/LanguageConfiguration.swift ios/LiveTranslate/Shared/LanguageConfigurationStore.swift ios/LiveTranslate/LiveTranslateTests/LanguageSelectionTests.swift
git commit -m "feat: add versioned language configuration"
```

---

### Task 2: Dynamic System Language Catalog

**Files:**
- Create: `ios/LiveTranslate/LiveTranslate/LanguageCatalogService.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/LanguageCatalogServiceTests.swift`

**Interfaces:**
- Consumes Task 1 option types.
- Produces `LanguageCatalogSnapshot`, `LanguageCatalogProviding`, and pure `LanguageCatalogBuilder`.

- [ ] **Step 1: Write failing mapping and de-duplication tests**

```swift
func testBuilderMapsSpeechLocalesToTranslationLanguages() {
    let catalog = LanguageCatalogBuilder.build(
        speechLocaleIdentifiers: ["ja-JP", "en-US", "zh-TW", "xx-YY"],
        translationLanguageIdentifiers: ["en", "ja", "zh-Hant", "de"],
        displayLocale: Locale(identifier: "zh-Hans")
    )
    XCTAssertEqual(Set(catalog.inputLanguages.map(\.localeIdentifier)), ["en-US", "ja-JP", "zh-TW"])
    XCTAssertEqual(
        catalog.inputLanguages.first { $0.localeIdentifier == "zh-TW" }?.translationLanguageIdentifier,
        "zh-Hant"
    )
}

func testBuilderDeduplicatesIdentifiersAndProducesNames() {
    let catalog = LanguageCatalogBuilder.build(
        speechLocaleIdentifiers: ["en-US", "en-US"],
        translationLanguageIdentifiers: ["ja", "ja"],
        displayLocale: Locale(identifier: "zh-Hans")
    )
    XCTAssertEqual(catalog.inputLanguages.count, 1)
    XCTAssertEqual(catalog.outputLanguages.count, 1)
    XCTAssertFalse(catalog.inputLanguages[0].displayName.isEmpty)
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguageCatalogServiceTests
```

- [ ] **Step 3: Implement the pure builder**

```swift
struct LanguageCatalogSnapshot: Equatable, Sendable {
    let inputLanguages: [SpeechLanguageOption]
    let outputLanguages: [TranslationLanguageOption]
}

protocol LanguageCatalogProviding: Sendable {
    func load(displayLocale: Locale) async throws -> LanguageCatalogSnapshot
}

enum LanguageCatalogBuilder {
    static func build(
        speechLocaleIdentifiers: [String],
        translationLanguageIdentifiers: [String],
        displayLocale: Locale
    ) -> LanguageCatalogSnapshot {
        let supported = Set(translationLanguageIdentifiers)
        let inputs = Set(speechLocaleIdentifiers).compactMap { identifier -> SpeechLanguageOption? in
            let language = Locale(identifier: identifier).language
            let code = language.languageCode?.identifier
            let script = language.script?.identifier
            let candidates = [language.minimalIdentifier, code.flatMap { c in script.map { "\(c)-\($0)" } }, code].compactMap { $0 }
            guard let translationIdentifier = candidates.first(where: supported.contains) else { return nil }
            return SpeechLanguageOption(
                localeIdentifier: identifier,
                translationLanguageIdentifier: translationIdentifier,
                displayName: displayLocale.localizedString(forIdentifier: identifier) ?? identifier
            )
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let outputs = supported.map {
            TranslationLanguageOption(
                languageIdentifier: $0,
                displayName: displayLocale.localizedString(forIdentifier: $0) ?? $0
            )
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return .init(inputLanguages: inputs, outputLanguages: outputs)
    }
}
```

- [ ] **Step 4: Add the read-only system adapter**

```swift
struct SystemLanguageCatalogService: LanguageCatalogProviding {
    func load(displayLocale: Locale) async throws -> LanguageCatalogSnapshot {
        let speechLocales = await SpeechTranscriber.supportedLocales
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        let translationLanguages = await availability.supportedLanguages
        return LanguageCatalogBuilder.build(
            speechLocaleIdentifiers: speechLocales.map(\.identifier),
            translationLanguageIdentifiers: translationLanguages.map(\.minimalIdentifier),
            displayLocale: displayLocale
        )
    }
}
```

This file must not call `assetInstallationRequest` or `prepareTranslation()`.

- [ ] **Step 5: Test, build, and commit**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguageCatalogServiceTests
xcodebuild build -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git add ios/LiveTranslate/LiveTranslate/LanguageCatalogService.swift ios/LiveTranslate/LiveTranslateTests/LanguageCatalogServiceTests.swift
git commit -m "feat: discover supported system languages"
```

---

### Task 3: Resource Status, Speech Preparation, Reservation, and Release

**Files:**
- Create: `ios/LiveTranslate/LiveTranslate/LanguageResourceService.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/LanguageResourceServiceTests.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/AppViewModel.swift` only to move `ModelResourceStatus` into the new file.

**Interfaces:**
- Produces `SpeechResourceState`, `LanguagePairResourceState`, and `LanguageResourceManaging`.
- `prepareSpeech(localeIdentifier:)` is the only Speech installation entry point.
- Translation installation remains owned by ContentView's explicit `translationTask`.

- [ ] **Step 1: Write failing readiness and explicit-call tests**

```swift
func testReadyRequiresInstalledReservedSpeechAndTranslation() {
    XCTAssertFalse(LanguagePairResourceState(
        speech: .init(status: .installed, isReserved: false),
        translation: .installed
    ).isReady)
    XCTAssertTrue(LanguagePairResourceState(
        speech: .init(status: .installed, isReserved: true),
        translation: .installed
    ).isReady)
}

func testPassThroughDoesNotRequireTranslationModel() {
    XCTAssertTrue(LanguagePairResourceState(
        speech: .init(status: .installed, isReserved: true),
        translation: .notRequired
    ).isReady)
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguageResourceServiceTests
```

- [ ] **Step 3: Add resource state and protocol**

```swift
enum ModelResourceStatus: Equatable, Sendable {
    case unknown, unsupported, needsDownload, downloading, installed, notRequired
}

struct SpeechResourceState: Equatable, Sendable {
    let status: ModelResourceStatus
    let isReserved: Bool
    var isReady: Bool { status == .installed && isReserved }
}

struct LanguagePairResourceState: Equatable, Sendable {
    let speech: SpeechResourceState
    let translation: ModelResourceStatus
    var isReady: Bool {
        speech.isReady && (translation == .installed || translation == .notRequired)
    }
}

protocol LanguageResourceManaging: Sendable {
    func status(for configuration: LanguagePairConfiguration) async -> LanguagePairResourceState
    func prepareSpeech(localeIdentifier: String) async throws
    func reservedSpeechLocaleIdentifiers() async -> [String]
    func releaseSpeech(localeIdentifier: String) async -> Bool
}
```

- [ ] **Step 4: Implement the system adapter**

```swift
struct SystemLanguageResourceService: LanguageResourceManaging {
    func status(for configuration: LanguagePairConfiguration) async -> LanguagePairResourceState {
        let locale = Locale(identifier: configuration.sourceSpeechLocaleIdentifier)
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let speech = map(await AssetInventory.status(forModules: [module]))
        let reserved = await AssetInventory.reservedLocales.contains { $0.identifier == locale.identifier }
        let translation: ModelResourceStatus
        if configuration.usesPassThroughTranslation {
            translation = .notRequired
        } else {
            let availability = LanguageAvailability(preferredStrategy: .lowLatency)
            translation = switch await availability.status(
                from: Locale.Language(identifier: configuration.sourceTranslationLanguageIdentifier),
                to: Locale.Language(identifier: configuration.targetTranslationLanguageIdentifier)
            ) {
            case .installed: .installed
            case .supported: .needsDownload
            case .unsupported: .unsupported
            @unknown default: .unknown
            }
        }
        return .init(speech: .init(status: speech, isReserved: reserved), translation: translation)
    }

    func prepareSpeech(localeIdentifier: String) async throws {
        let locale = Locale(identifier: localeIdentifier)
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [module]) != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                throw LanguageResourceError.installationUnavailable
            }
            try await request.downloadAndInstall()
        }
        if await AssetInventory.reservedLocales.contains(where: { $0.identifier == locale.identifier }) {
            return
        }
        guard try await AssetInventory.reserve(locale: locale) else {
            throw LanguageResourceError.reservationUnavailable
        }
    }

    func reservedSpeechLocaleIdentifiers() async -> [String] {
        await AssetInventory.reservedLocales.map(\.identifier).sorted()
    }

    func releaseSpeech(localeIdentifier: String) async -> Bool {
        await AssetInventory.release(reservedLocale: Locale(identifier: localeIdentifier))
    }
}
```

Define `LanguageResourceError` with concrete Chinese descriptions for `installationUnavailable` and `reservationUnavailable`, and add an exhaustive `AssetInventory.Status` mapper.

- [ ] **Step 5: Test, build, and commit**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguageResourceServiceTests
xcodebuild build -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git add ios/LiveTranslate/LiveTranslate/LanguageResourceService.swift ios/LiveTranslate/LiveTranslateTests/LanguageResourceServiceTests.swift
git add -p ios/LiveTranslate/LiveTranslate/AppViewModel.swift
git commit -m "feat: manage language model resources"
```

---

### Task 4: Dynamic App State and Explicit Translation Preparation

**Files:**
- Modify: `ios/LiveTranslate/LiveTranslate/AppViewModel.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/ContentView.swift`
- Modify: `ios/LiveTranslate/LiveTranslateTests/AppViewModelTests.swift`
- Modify: `ios/LiveTranslate/LiveTranslateTests/TestDoubles.swift`

**Interfaces:**
- Consumes catalog, resource, and configuration-store protocols.
- Produces dynamic options, selected pair, resource state, and `canStartBroadcast`.
- Produces `beginModelPreparation() -> ModelPreparationAction`; only `.prepareTranslation` creates a Translation configuration.
- Replaces the initializer with `init(catalogService:resourceService:store:languageStore:displayLocale:)`; `displayLocale` defaults to `.current` and the other arguments use the protocols defined in Tasks 1-3.

- [ ] **Step 1: Add recording fakes and failing state-machine tests**

Start with these concrete tests and retain the existing late-result tests by changing their keys from `SourceLanguage` to `LanguagePairConfiguration`:

```swift
func testLoadingLanguagesDoesNotPrepareResources() async {
    let resources = RecordingLanguageResourceService()
    await resources.setState(
        .init(speech: .init(status: .needsDownload, isReserved: false), translation: .needsDownload),
        for: LanguageTestFixture.pair
    )
    let viewModel = AppViewModel(
        catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
        resourceService: resources,
        store: InMemoryCaptionStore(),
        languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
        displayLocale: Locale(identifier: "zh-Hans")
    )

    await viewModel.loadLanguages()

    XCTAssertEqual(await resources.preparedSpeechLocales, [])
    XCTAssertFalse(viewModel.canStartBroadcast)
}

func testExplicitPreparationInstallsSpeechThenRequestsTranslation() async {
    let resources = RecordingLanguageResourceService()
    await resources.setState(
        .init(speech: .init(status: .needsDownload, isReserved: false), translation: .needsDownload),
        for: LanguageTestFixture.pair
    )
    let viewModel = AppViewModel(
        catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
        resourceService: resources,
        store: InMemoryCaptionStore(),
        languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
        displayLocale: Locale(identifier: "zh-Hans")
    )
    await viewModel.loadLanguages()

    let action = await viewModel.beginModelPreparation()

    XCTAssertEqual(await resources.preparedSpeechLocales, ["fr-FR"])
    XCTAssertEqual(action, .prepareTranslation(LanguageTestFixture.pair))
}

func testUnsupportedPairCannotPrepareOrBroadcast() async {
    let resources = RecordingLanguageResourceService()
    await resources.setState(
        .init(speech: .init(status: .installed, isReserved: true), translation: .unsupported),
        for: LanguageTestFixture.pair
    )
    let viewModel = AppViewModel(
        catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
        resourceService: resources,
        store: InMemoryCaptionStore(),
        languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
        displayLocale: Locale(identifier: "zh-Hans")
    )
    await viewModel.loadLanguages()

    XCTAssertEqual(await viewModel.beginModelPreparation(), .none)
    XCTAssertFalse(viewModel.canStartBroadcast)
}
```

Add these two pair-specific tests:

```swift
func testChangingOutputPersistsTheFullPair() async {
    let chinese = TranslationLanguageOption(languageIdentifier: "zh-Hans", displayName: "简体中文")
    let catalog = LanguageCatalogSnapshot(
        inputLanguages: [LanguageTestFixture.input],
        outputLanguages: [LanguageTestFixture.output, chinese]
    )
    let store = InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair)
    let viewModel = AppViewModel(
        catalogService: FixedLanguageCatalogService(snapshot: catalog),
        resourceService: RecordingLanguageResourceService(),
        store: InMemoryCaptionStore(),
        languageStore: store,
        displayLocale: Locale(identifier: "zh-Hans")
    )
    await viewModel.loadLanguages()

    await viewModel.selectOutput(identifier: "zh-Hans")

    XCTAssertEqual(
        store.load()?.targetTranslationLanguageIdentifier,
        "zh-Hans"
    )
}

func testPassThroughPairNeedsNoTranslationTask() async {
    let frenchOutput = TranslationLanguageOption(languageIdentifier: "fr", displayName: "法语")
    let pair = LanguagePairConfiguration(
        sourceSpeechLocaleIdentifier: "fr-FR",
        sourceTranslationLanguageIdentifier: "fr",
        targetTranslationLanguageIdentifier: "fr"
    )
    let resources = RecordingLanguageResourceService()
    await resources.setState(
        .init(speech: .init(status: .installed, isReserved: true), translation: .notRequired),
        for: pair
    )
    let viewModel = AppViewModel(
        catalogService: FixedLanguageCatalogService(
            snapshot: .init(inputLanguages: [LanguageTestFixture.input], outputLanguages: [frenchOutput])
        ),
        resourceService: resources,
        store: InMemoryCaptionStore(),
        languageStore: InMemoryLanguageConfigurationStore(value: pair),
        displayLocale: Locale(identifier: "zh-Hans")
    )
    await viewModel.loadLanguages()

    XCTAssertEqual(await viewModel.beginModelPreparation(), .none)
    XCTAssertTrue(viewModel.canStartBroadcast)
}
```

Keep the two existing late-result tests, changing their continuation keys from `SourceLanguage` to `LanguagePairConfiguration`; their original assertions that an old result cannot overwrite the current selection remain unchanged.

Add these reusable test doubles in `TestDoubles.swift`:

```swift
struct FixedLanguageCatalogService: LanguageCatalogProviding {
    let snapshot: LanguageCatalogSnapshot
    func load(displayLocale: Locale) async throws -> LanguageCatalogSnapshot { snapshot }
}

final class InMemoryLanguageConfigurationStore: LanguageConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LanguagePairConfiguration?
    init(value: LanguagePairConfiguration? = nil) { self.value = value }
    func load() -> LanguagePairConfiguration? { lock.withLock { value } }
    func save(_ configuration: LanguagePairConfiguration) {
        lock.withLock { value = configuration }
    }
}

actor RecordingLanguageResourceService: LanguageResourceManaging {
    private var states: [LanguagePairConfiguration: LanguagePairResourceState] = [:]
    private(set) var preparedSpeechLocales: [String] = []
    private(set) var releasedSpeechLocales: [String] = []
    var reservedLocales: [String] = []

    func setState(_ state: LanguagePairResourceState, for pair: LanguagePairConfiguration) {
        states[pair] = state
    }
    func status(for pair: LanguagePairConfiguration) async -> LanguagePairResourceState {
        states[pair] ?? .init(
            speech: .init(status: .unknown, isReserved: false),
            translation: .unknown
        )
    }
    func prepareSpeech(localeIdentifier: String) async throws {
        preparedSpeechLocales.append(localeIdentifier)
        for pair in Array(states.keys) where pair.sourceSpeechLocaleIdentifier == localeIdentifier {
            guard let current = states[pair] else { continue }
            states[pair] = .init(
                speech: .init(status: .installed, isReserved: true),
                translation: current.translation
            )
        }
    }
    func reservedSpeechLocaleIdentifiers() async -> [String] { reservedLocales }
    func releaseSpeech(localeIdentifier: String) async -> Bool {
        releasedSpeechLocales.append(localeIdentifier)
        reservedLocales.removeAll { $0 == localeIdentifier }
        for pair in Array(states.keys) where pair.sourceSpeechLocaleIdentifier == localeIdentifier {
            guard let current = states[pair] else { continue }
            states[pair] = .init(
                speech: .init(status: current.speech.status, isReserved: false),
                translation: current.translation
            )
        }
        return true
    }
}

enum LanguageTestFixture {
    static let input = SpeechLanguageOption(
        localeIdentifier: "fr-FR",
        translationLanguageIdentifier: "fr",
        displayName: "法语（法国）"
    )
    static let output = TranslationLanguageOption(
        languageIdentifier: "de",
        displayName: "德语"
    )
    static let pair = LanguagePairConfiguration(
        sourceSpeechLocaleIdentifier: "fr-FR",
        sourceTranslationLanguageIdentifier: "fr",
        targetTranslationLanguageIdentifier: "de"
    )
    static let catalog = LanguageCatalogSnapshot(
        inputLanguages: [input],
        outputLanguages: [output]
    )
}
```

- [ ] **Step 2: Run AppViewModel tests and confirm failure**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/AppViewModelTests
```

- [ ] **Step 3: Replace the hard-coded selection with these published shapes**

```swift
enum ModelPreparationAction: Equatable, Sendable {
    case none
    case prepareTranslation(LanguagePairConfiguration)
}

enum ModelPreparationPhase: Equatable, Sendable {
    case idle, preparingSpeech, preparingTranslation
}

@Published private(set) var inputLanguages: [SpeechLanguageOption] = []
@Published private(set) var outputLanguages: [TranslationLanguageOption] = []
@Published var selectedInput: SpeechLanguageOption?
@Published var selectedOutput: TranslationLanguageOption?
@Published private(set) var resourceState = LanguagePairResourceState(
    speech: .init(status: .unknown, isReserved: false),
    translation: .unknown
)
@Published private(set) var preparationPhase: ModelPreparationPhase = .idle

var currentConfiguration: LanguagePairConfiguration? {
    guard let selectedInput, let selectedOutput else { return nil }
    return .init(
        sourceSpeechLocaleIdentifier: selectedInput.localeIdentifier,
        sourceTranslationLanguageIdentifier: selectedInput.translationLanguageIdentifier,
        targetTranslationLanguageIdentifier: selectedOutput.languageIdentifier
    )
}
```

`loadLanguages()` calls `try await catalogService.load(displayLocale:)`, restores a still-valid saved pair, otherwise prefers the current system input and `zh-Hans`, then saves the resolved pair and calls only `refreshResourceStatus()`. Guard async write-backs with a monotonically increasing request generation. Catch catalog errors or empty catalogs as `languageCatalogErrorMessage`, keep the broadcast disabled, and expose a “重新加载语言” button that calls `loadLanguages()` again without preparing resources.

Selection changes use exact methods so ContentView never mutates an option without persistence and status invalidation:

```swift
func selectInput(identifier: String) async {
    guard let option = inputLanguages.first(where: { $0.localeIdentifier == identifier }) else { return }
    selectedInput = option
    persistCurrentConfiguration()
    await refreshResourceStatus()
}

func selectOutput(identifier: String) async {
    guard let option = outputLanguages.first(where: { $0.languageIdentifier == identifier }) else { return }
    selectedOutput = option
    persistCurrentConfiguration()
    await refreshResourceStatus()
}
```

- [ ] **Step 4: Implement the single-button preparation action**

```swift
func beginModelPreparation() async -> ModelPreparationAction {
    guard let request = currentConfiguration,
          resourceState.translation != .unsupported else { return .none }
    preparationPhase = .preparingSpeech
    do {
        if !resourceState.speech.isReady {
            try await resourceService.prepareSpeech(
                localeIdentifier: request.sourceSpeechLocaleIdentifier
            )
        }
        guard request == currentConfiguration else { return .none }
        await refreshResourceStatus()
        guard request == currentConfiguration else { return .none }
        if resourceState.translation == .needsDownload {
            preparationPhase = .preparingTranslation
            return .prepareTranslation(request)
        }
        preparationPhase = .idle
        return .none
    } catch {
        guard request == currentConfiguration else { return .none }
        preparationPhase = .idle
        modelErrorMessage = "模型准备失败：\(error.localizedDescription)"
        refreshErrorMessage()
        return .none
    }
}

func finishTranslationPreparation(
    for configuration: LanguagePairConfiguration,
    error: (any Error)?
) async {
    guard configuration == currentConfiguration else { return }
    preparationPhase = .idle
    modelErrorMessage = error.map { "翻译模型准备失败：\($0.localizedDescription)" }
    await refreshResourceStatus()
    refreshErrorMessage()
}
```

- [ ] **Step 5: Make the button the only Translation download trigger**

```swift
Button("下载所需模型") {
    Task {
        guard case .prepareTranslation(let pair) = await viewModel.beginModelPreparation() else {
            return
        }
        translationPreparation = pair
        translationConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: pair.sourceTranslationLanguageIdentifier),
            target: Locale.Language(identifier: pair.targetTranslationLanguageIdentifier),
            preferredStrategy: .lowLatency
        )
    }
}
.translationTask(translationConfiguration) { session in
    guard let pair = translationPreparation else { return }
    do {
        try await session.prepareTranslation()
        await viewModel.finishTranslationPreparation(for: pair, error: nil)
    } catch {
        await viewModel.finishTranslationPreparation(for: pair, error: error)
    }
    translationPreparation = nil
    translationConfiguration = nil
}
```

Remove automatic `configureTranslation()` calls from `.task`, `.onAppear`, and selection changes.

- [ ] **Step 6: Test, build, and commit**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/AppViewModelTests
xcodebuild build -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git add ios/LiveTranslate/LiveTranslate/AppViewModel.swift ios/LiveTranslate/LiveTranslate/ContentView.swift ios/LiveTranslate/LiveTranslateTests/AppViewModelTests.swift ios/LiveTranslate/LiveTranslateTests/TestDoubles.swift
git commit -m "feat: prepare selected models on demand"
```

---

### Task 5: Searchable Language Selection UI

**Files:**
- Create: `ios/LiveTranslate/LiveTranslate/LanguagePickerView.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/LanguagePickerViewTests.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/ContentView.swift`

**Interfaces:**
- Consumes dynamic input/output options by stable identifier.
- Produces a reusable searchable list; display names are never persistence keys.

- [ ] **Step 1: Write failing filter tests**

```swift
func testFilterMatchesLocalizedNameAndStableIdentifier() {
    let items = [
        LanguagePickerItem(id: "ja-JP", title: "日语（日本）"),
        LanguagePickerItem(id: "en-US", title: "英语（美国）")
    ]
    XCTAssertEqual(LanguagePickerFilter.filter(items, query: "日语").map(\.id), ["ja-JP"])
    XCTAssertEqual(LanguagePickerFilter.filter(items, query: "en-US").map(\.id), ["en-US"])
    XCTAssertEqual(LanguagePickerFilter.filter(items, query: "").count, 2)
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguagePickerViewTests
```

- [ ] **Step 3: Implement the filter and searchable list**

```swift
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
                    Text(item.title)
                    Spacer()
                    if selection == item.id { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "搜索语言")
    }
}
```

- [ ] **Step 4: Integrate separate input and output navigation rows**

Map selections through asynchronous ViewModel methods so display text is never persisted:

```swift
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
```

Build picker items with localized titles and stable identifiers. Show the identifier as secondary text when two rows share a localized title.

- [ ] **Step 5: Test, build, and commit**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/LanguagePickerViewTests -only-testing:LiveTranslateTests/AppViewModelTests
xcodebuild build -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git add ios/LiveTranslate/LiveTranslate/LanguagePickerView.swift ios/LiveTranslate/LiveTranslateTests/LanguagePickerViewTests.swift ios/LiveTranslate/LiveTranslate/ContentView.swift
git commit -m "feat: add searchable language selectors"
```

---

### Task 6: Speech Model Management and Bounded Caption Cache

**Files:**
- Create: `ios/LiveTranslate/LiveTranslate/SpeechModelManagementView.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/SpeechModelManagementTests.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/AppViewModel.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/ContentView.swift`
- Modify: `ios/LiveTranslate/Shared/BroadcastCaptionCoordinator.swift`
- Modify: `ios/LiveTranslate/LiveTranslateTests/BroadcastCaptionCoordinatorTests.swift`

**Interfaces:**
- Consumes reservation list and release methods from Task 3.
- Produces ViewModel reservation-management methods.
- Changes `BroadcastCaptionCoordinator.begin()` to clear the previous snapshot before its first write.

- [ ] **Step 1: Write failing release and cache-reset tests**

```swift
func testReleasingCurrentSpeechLocaleDisablesBroadcast() async {
    let input = SpeechLanguageOption(
        localeIdentifier: "en-US",
        translationLanguageIdentifier: "en",
        displayName: "英语（美国）"
    )
    let output = TranslationLanguageOption(
        languageIdentifier: "zh-Hans",
        displayName: "简体中文"
    )
    let pair = LanguagePairConfiguration(
        sourceSpeechLocaleIdentifier: "en-US",
        sourceTranslationLanguageIdentifier: "en",
        targetTranslationLanguageIdentifier: "zh-Hans"
    )
    let resourceService = RecordingLanguageResourceService()
    await resourceService.setState(
        .init(
            speech: .init(status: .installed, isReserved: true),
            translation: .installed
        ),
        for: pair
    )
    let viewModel = AppViewModel(
        catalogService: FixedLanguageCatalogService(
            snapshot: .init(inputLanguages: [input], outputLanguages: [output])
        ),
        resourceService: resourceService,
        store: InMemoryCaptionStore(),
        languageStore: InMemoryLanguageConfigurationStore(value: pair),
        displayLocale: Locale(identifier: "zh-Hans")
    )
    await viewModel.loadLanguages()
    await viewModel.releaseSpeechLocale("en-US")
    XCTAssertFalse(viewModel.canStartBroadcast)
    XCTAssertEqual(await resourceService.releasedSpeechLocales, ["en-US"])
}

func testBeginningNewBroadcastClearsPreviousCaptionText() throws {
    let store = InMemoryCaptionStore()
    try store.save(.init(
        revision: 99,
        sourceText: "old",
        translatedText: "旧译文",
        phase: .stopped,
        errorMessage: nil,
        updatedAt: .now
    ))
    let coordinator = BroadcastCaptionCoordinator(store: store)
    try coordinator.begin()
    XCTAssertEqual(try store.load()?.sourceText, "")
    XCTAssertEqual(try store.load()?.translatedText, "")
    XCTAssertEqual(try store.load()?.phase, .broadcasting)
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/SpeechModelManagementTests -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests/testBeginningNewBroadcastClearsPreviousCaptionText
```

- [ ] **Step 3: Add reservation management to AppViewModel**

```swift
@Published private(set) var reservedSpeechLocaleIdentifiers: [String] = []

func loadReservedSpeechLocales() async {
    reservedSpeechLocaleIdentifiers = await resourceService.reservedSpeechLocaleIdentifiers()
}

func releaseSpeechLocale(_ identifier: String) async {
    guard preparationPhase == .idle else { return }
    guard await resourceService.releaseSpeech(localeIdentifier: identifier) else {
        modelErrorMessage = "无法释放语音模型 \(identifier)。"
        refreshErrorMessage()
        return
    }
    await loadReservedSpeechLocales()
    if currentConfiguration?.sourceSpeechLocaleIdentifier == identifier {
        await refreshResourceStatus()
    }
}
```

- [ ] **Step 4: Add the management screen and system-owned Translation notice**

```swift
struct SpeechModelManagementView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            Section("已保留的语音模型") {
                if viewModel.reservedSpeechLocaleIdentifiers.isEmpty {
                    Text("没有由本 App 保留的语音模型").foregroundStyle(.secondary)
                }
                ForEach(viewModel.reservedSpeechLocaleIdentifiers, id: \.self) { identifier in
                    LabeledContent(identifier) {
                        Button("释放", role: .destructive) {
                            Task { await viewModel.releaseSpeechLocale(identifier) }
                        }
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
```

Add a navigation row from ContentView. Disable release buttons while preparation is active.

- [ ] **Step 5: Clear the old snapshot without touching existing latency logic**

```swift
func begin() throws {
    try lock.withLock {
        guard lifecycle != .terminal else { return }
        try store.clear()
        try write(sourceText: "", translatedText: "", phase: .broadcasting, errorMessage: nil)
        lifecycle = .active
    }
}
```

- [ ] **Step 6: Test and commit only the intended coordinator hunk**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/SpeechModelManagementTests -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests -only-testing:LiveTranslateTests/CaptionStoreTests
git diff -- ios/LiveTranslate/Shared/BroadcastCaptionCoordinator.swift
git add ios/LiveTranslate/LiveTranslate/SpeechModelManagementView.swift ios/LiveTranslate/LiveTranslateTests/SpeechModelManagementTests.swift ios/LiveTranslate/LiveTranslate/AppViewModel.swift ios/LiveTranslate/LiveTranslate/ContentView.swift ios/LiveTranslate/LiveTranslateTests/BroadcastCaptionCoordinatorTests.swift
git add -p ios/LiveTranslate/Shared/BroadcastCaptionCoordinator.swift
git commit -m "feat: manage speech models and bound caption cache"
```

---

### Task 7: Broadcast Extension Uses the Full Language Pair

**Files:**
- Modify: `ios/LiveTranslate/LiveTranslateBroadcast/SpeechPipeline.swift`
- Modify: `ios/LiveTranslate/LiveTranslateBroadcast/AppleTranslationClient.swift`
- Modify: `ios/LiveTranslate/LiveTranslateBroadcast/SampleHandler.swift`
- Create: `ios/LiveTranslate/Shared/TranslationRouting.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/TranslationClientConfigurationTests.swift`
- Delete: `ios/LiveTranslate/Shared/LanguageSelection.swift`
- Delete: `ios/LiveTranslate/Shared/SourceLanguageStore.swift`
- Delete: `ios/LiveTranslate/LiveTranslate/ModelPreparationService.swift`

**Interfaces:**
- Consumes `LanguagePairConfiguration` from App Group.
- Changes Speech startup to `sourceLocaleIdentifier: String`.
- Produces shared `TranslationClientConfiguration` and `PassThroughTranslationClient`, so the App test target can test routing without importing the extension target.

- [ ] **Step 1: Write failing arbitrary-pair and pass-through tests**

```swift
func testTranslationClientConfigurationUsesStoredPair() {
    let pair = LanguagePairConfiguration(
        sourceSpeechLocaleIdentifier: "fr-FR",
        sourceTranslationLanguageIdentifier: "fr",
        targetTranslationLanguageIdentifier: "de"
    )
    XCTAssertEqual(TranslationClientConfiguration(pair).sourceIdentifier, "fr")
    XCTAssertEqual(TranslationClientConfiguration(pair).targetIdentifier, "de")
}

func testPassThroughTranslatorReturnsRecognizedText() async throws {
    XCTAssertEqual(try await PassThroughTranslationClient().translate("同じ言語"), "同じ言語")
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/TranslationClientConfigurationTests
```

- [ ] **Step 3: Generalize SpeechPipeline**

```swift
static func start(
    sourceLocaleIdentifier: String,
    onText: @escaping @Sendable (String) async -> Void,
    onFailure: @escaping @Sendable (any Error) async -> Void = { _ in }
) async throws -> SpeechPipeline {
    let transcriber = SpeechTranscriber(
        locale: Locale(identifier: sourceLocaleIdentifier),
        preset: .progressiveTranscription
    )
    // Preserve the existing analyzer, queue, conversion, result, and cleanup code.
}
```

- [ ] **Step 4: Generalize installed-only Translation and add pass-through**

```swift
// Shared/TranslationRouting.swift
struct TranslationClientConfiguration: Equatable, Sendable {
    let sourceIdentifier: String
    let targetIdentifier: String

    init(_ pair: LanguagePairConfiguration) {
        sourceIdentifier = pair.sourceTranslationLanguageIdentifier
        targetIdentifier = pair.targetTranslationLanguageIdentifier
    }
}

struct PassThroughTranslationClient: CaptionTranslating {
    func translate(_ text: String) async throws -> String { text }
}
```

Change `AppleTranslationClient` to construct source and target `Locale.Language` values from this configuration and keep the existing low-latency strategy, serial executor, availability check, and stale-response behavior. Error messages must refer to the current pair, not fixed Simplified Chinese.

- [ ] **Step 5: Read the complete configuration in SampleHandler**

```swift
let configurationStore = try LanguageConfigurationStore()
guard let configuration = configurationStore.load() else {
    throw BroadcastCaptureError.languageConfigurationMissing
}
let translator: any CaptionTranslating = configuration.usesPassThroughTranslation
    ? PassThroughTranslationClient()
    : AppleTranslationClient(configuration: TranslationClientConfiguration(configuration))
```

Pass `configuration.sourceSpeechLocaleIdentifier` through `runAudioSession` to SpeechPipeline. The extension must treat Translation `.supported` as “not installed” and fail; it must never call `prepareTranslation()`.

- [ ] **Step 6: Remove legacy types after all references are gone**

```bash
rg -n 'SourceLanguage|SourceLanguageStore|ModelPreparing|ModelPreparationService|translationTarget' ios/LiveTranslate -g '*.swift'
```

Expected before deletion: matches only in the three legacy files. Delete them, rerun the command, and expect no matches.

- [ ] **Step 7: Test, build, and commit**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:LiveTranslateTests/TranslationClientConfigurationTests -only-testing:LiveTranslateTests/BroadcastAudioSupportTests -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests
xcodebuild build -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git add ios/LiveTranslate/LiveTranslateBroadcast/SpeechPipeline.swift ios/LiveTranslate/LiveTranslateBroadcast/AppleTranslationClient.swift ios/LiveTranslate/LiveTranslateBroadcast/SampleHandler.swift ios/LiveTranslate/Shared/TranslationRouting.swift ios/LiveTranslate/LiveTranslateTests/TranslationClientConfigurationTests.swift ios/LiveTranslate/Shared/LanguageSelection.swift ios/LiveTranslate/Shared/SourceLanguageStore.swift ios/LiveTranslate/LiveTranslate/ModelPreparationService.swift
git commit -m "feat: run broadcasts with arbitrary language pairs"
```

---

### Task 8: Full Regression and iPhone Handoff

**Files:**
- Modify only files from Tasks 1-7 if a verified failure needs a minimal fix.

**Interfaces:**
- Verifies the complete spec; produces no new feature API.

- [ ] **Step 1: Audit every potential automatic-download call**

```bash
rg -n 'prepareTranslation\(|assetInstallationRequest\(' ios/LiveTranslate -g '*.swift'
```

Expected: `prepareTranslation()` appears only in the explicit button-triggered `translationTask`; `assetInstallationRequest` appears only in `prepareSpeech`. Neither appears in lifecycle callbacks, catalog/status code, or the broadcast extension.

- [ ] **Step 2: Run the complete unit test suite**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

Expected: `** TEST SUCCEEDED **`, including existing PiP, latency, long-caption, and audio tests.

- [ ] **Step 3: Run a clean unsigned simulator build**

```bash
xcodebuild clean build -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Review scope and dirty-worktree preservation**

```bash
git status --short
git diff --check
git diff --stat
git diff -- ios/LiveTranslate/LiveTranslate.xcodeproj/project.pbxproj
```

Expected: no unintended signing, App Group, AppIcon, telemetry, server, dependency, or project-file changes. Pre-existing user changes remain intact unless deliberately included and verified.

- [ ] **Step 5: Build for the connected iPhone**

```bash
xcodebuild build -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS,id=00008140-000559890A39801C'
```

Expected: signed device build succeeds. If the device is disconnected, report this check as pending rather than replacing it with a simulator claim.

- [ ] **Step 6: Complete the manual iPhone checklist**

1. Launch and confirm no automatic download prompt.
2. Explicitly download and test English to Simplified Chinese.
3. Explicitly download and test Japanese to Simplified Chinese.
4. Test one supported non-Chinese output pair, such as French to German.
5. Test identical source and target; confirm no Translation download request.
6. Release a Speech locale and confirm the broadcast control disables for it.
7. Start a new broadcast and confirm the old caption is gone.
8. Relaunch and confirm there is no history UI or growing archive.

- [ ] **Step 7: Commit only verified minimal fixes, if any**

If Step 2-6 exposed a defect, return to the task that owns that file, add a reproducing test, apply the minimal fix, rerun that task's focused check and the full suite, and commit with that task's exact file list. If no defect was found, do not create an empty commit.

import Foundation

protocol BroadcastSpeechAssetInventoryAccessing: Sendable {
    func installationStatus(
        localeIdentifier: String
    ) async -> BroadcastInstalledResourceStatus
    func reservedLocaleIdentifiers() async -> [String]
    func reserve(localeIdentifier: String) async throws -> Bool
}

struct BroadcastSpeechResourceResolver: Sendable {
    private let inventory: any BroadcastSpeechAssetInventoryAccessing

    init(inventory: any BroadcastSpeechAssetInventoryAccessing) {
        self.inventory = inventory
    }

    func status(
        localeIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        let installationStatus = await inventory.installationStatus(
            localeIdentifier: localeIdentifier
        )
        guard installationStatus == .installed || installationStatus == .available else {
            return installationStatus
        }

        let requestedIdentifier = normalized(localeIdentifier)
        let isReserved = await inventory.reservedLocaleIdentifiers().contains {
            normalized($0) == requestedIdentifier
        }
        if isReserved {
            return await inventory.installationStatus(
                localeIdentifier: localeIdentifier
            )
        }

        do {
            _ = try await inventory.reserve(localeIdentifier: localeIdentifier)
            return await inventory.installationStatus(
                localeIdentifier: localeIdentifier
            )
        } catch {
            return .available
        }
    }

    private func normalized(_ identifier: String) -> String {
        Locale.identifier(.bcp47, from: identifier)
    }
}

import XCTest
@testable import LiveTranslate

final class BroadcastSpeechResourceResolverTests: XCTestCase {
    func testAvailableAssetBecomesReadyAfterReservationAndStatusRefresh() async {
        let inventory = ReservationActivatedBroadcastSpeechAssetInventory()
        let resolver = BroadcastSpeechResourceResolver(inventory: inventory)

        let status = await resolver.status(localeIdentifier: "en_GB")

        XCTAssertEqual(status, .installed)
    }

    func testInstalledAssetIsReadyAfterExtensionReservationSucceeds() async {
        let inventory = RecordingBroadcastSpeechAssetInventory(
            status: .installed,
            reservedLocaleIdentifiers: [],
            reserveResult: true
        )
        let resolver = BroadcastSpeechResourceResolver(inventory: inventory)

        let status = await resolver.status(localeIdentifier: "en_US")
        let reserveRequests = await inventory.reserveRequests

        XCTAssertEqual(status, .installed)
        XCTAssertEqual(reserveRequests, ["en_US"])
    }

    func testEquivalentReservedIdentifierDoesNotReserveAgain() async {
        let inventory = RecordingBroadcastSpeechAssetInventory(
            status: .installed,
            reservedLocaleIdentifiers: ["en-US"],
            reserveResult: false
        )
        let resolver = BroadcastSpeechResourceResolver(inventory: inventory)

        let status = await resolver.status(localeIdentifier: "en_US")
        let reserveRequests = await inventory.reserveRequests

        XCTAssertEqual(status, .installed)
        XCTAssertEqual(reserveRequests, [])
    }

    func testInstalledAssetIsReadyWhenReserveReportsLocaleWasAlreadyReserved() async {
        let inventory = RecordingBroadcastSpeechAssetInventory(
            status: .installed,
            reservedLocaleIdentifiers: [],
            reserveResult: false
        )
        let resolver = BroadcastSpeechResourceResolver(inventory: inventory)

        let status = await resolver.status(localeIdentifier: "en_US")

        XCTAssertEqual(status, .installed)
    }

    func testInstalledAssetRemainsUnavailableWhenExtensionReservationThrows() async {
        let inventory = RecordingBroadcastSpeechAssetInventory(
            status: .installed,
            reservedLocaleIdentifiers: [],
            reserveError: TestReservationError.failed
        )
        let resolver = BroadcastSpeechResourceResolver(inventory: inventory)

        let status = await resolver.status(localeIdentifier: "en_US")

        XCTAssertEqual(status, .available)
    }
}

private actor ReservationActivatedBroadcastSpeechAssetInventory:
    BroadcastSpeechAssetInventoryAccessing
{
    private var isReserved = false

    func installationStatus(
        localeIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        isReserved ? .installed : .available
    }

    func reservedLocaleIdentifiers() async -> [String] {
        []
    }

    func reserve(localeIdentifier: String) async throws -> Bool {
        isReserved = true
        return true
    }
}

private enum TestReservationError: Error {
    case failed
}

private actor RecordingBroadcastSpeechAssetInventory: BroadcastSpeechAssetInventoryAccessing {
    let statusValue: BroadcastInstalledResourceStatus
    let reservedLocaleIdentifiersValue: [String]
    let reserveResult: Bool
    let reserveError: (any Error)?
    private(set) var reserveRequests: [String] = []

    init(
        status: BroadcastInstalledResourceStatus,
        reservedLocaleIdentifiers: [String],
        reserveResult: Bool = true,
        reserveError: (any Error)? = nil
    ) {
        statusValue = status
        reservedLocaleIdentifiersValue = reservedLocaleIdentifiers
        self.reserveResult = reserveResult
        self.reserveError = reserveError
    }

    func installationStatus(
        localeIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        statusValue
    }

    func reservedLocaleIdentifiers() async -> [String] {
        reservedLocaleIdentifiersValue
    }

    func reserve(localeIdentifier: String) async throws -> Bool {
        reserveRequests.append(localeIdentifier)
        if let reserveError {
            throw reserveError
        }
        return reserveResult
    }
}

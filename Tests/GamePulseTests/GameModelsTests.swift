import XCTest
@testable import GamePulse

final class GameModelsTests: XCTestCase {
    func testStaminaRecoversAndCaps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let stamina = StaminaSnapshot(
            current: 10,
            maximum: 20,
            capturedAt: start,
            recoverySecondsPerUnit: 60
        )

        XCTAssertEqual(stamina.value(at: start.addingTimeInterval(5 * 60)), 15)
        XCTAssertEqual(stamina.value(at: start.addingTimeInterval(60 * 60)), 20)
    }

    func testFullTimeUsesRemainingUnits() {
        let start = Date(timeIntervalSince1970: 1_000)
        let stamina = StaminaSnapshot(
            current: 10,
            maximum: 20,
            capturedAt: start,
            recoverySecondsPerUnit: 60
        )

        XCTAssertEqual(stamina.fullAt(from: start), start.addingTimeInterval(600))
    }
}

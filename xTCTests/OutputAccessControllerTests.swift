import XCTest
@testable import xTC

@MainActor
final class OutputAccessControllerTests: XCTestCase {
  func testLockedUserCannotStartOutput() {
    var starts = 0
    let controller = OutputAccessController(stopMIDI: {}, stopLTC: {})

    let allowed = controller.requestOutput { starts += 1 }

    XCTAssertFalse(allowed)
    XCTAssertEqual(starts, 0)
  }

  func testUnlockedUserCanStartOutput() {
    var starts = 0
    let controller = OutputAccessController(stopMIDI: {}, stopLTC: {})
    controller.setUnlocked(true)

    let allowed = controller.requestOutput { starts += 1 }

    XCTAssertTrue(allowed)
    XCTAssertEqual(starts, 1)
  }

  func testLosingEntitlementStopsBothPipelines() {
    var midiStops = 0
    var ltcStops = 0
    let controller = OutputAccessController(
      stopMIDI: { midiStops += 1 },
      stopLTC: { ltcStops += 1 }
    )
    controller.setUnlocked(true)

    controller.setUnlocked(false)

    XCTAssertEqual(midiStops, 1)
    XCTAssertEqual(ltcStops, 1)
  }
}

import XCTest
@testable import xTC

final class EntitlementStateTests: XCTestCase {
  func testVerifiedCurrentProductUnlocksPro() {
    let state = EntitlementSnapshot.resolve(
      currentProductIDs: ["com.luoxiliu.xtc.pro"],
      revokedProductIDs: []
    )
    XCTAssertEqual(state, .unlocked)
  }

  func testMissingProductRemainsLocked() {
    let state = EntitlementSnapshot.resolve(
      currentProductIDs: [],
      revokedProductIDs: []
    )
    XCTAssertEqual(state, .locked)
  }

  func testRevocationOverridesCurrentProduct() {
    let state = EntitlementSnapshot.resolve(
      currentProductIDs: ["com.luoxiliu.xtc.pro"],
      revokedProductIDs: ["com.luoxiliu.xtc.pro"]
    )
    XCTAssertEqual(state, .locked)
  }
}

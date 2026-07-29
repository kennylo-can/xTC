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

  func testPurchaseCopyExistsInBothLanguages() {
    XCTAssertEqual(
      AppLanguageStore.text("Unlock xTC Pro", "解锁 xTC Pro", language: .english),
      "Unlock xTC Pro"
    )
    XCTAssertEqual(
      AppLanguageStore.text("Unlock xTC Pro", "解锁 xTC Pro", language: .simplifiedChinese),
      "解锁 xTC Pro"
    )
  }
}

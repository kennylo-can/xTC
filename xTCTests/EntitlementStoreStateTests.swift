import XCTest
@testable import xTC

@MainActor
final class EntitlementStoreStateTests: XCTestCase {
  func testFailedRefreshPreservesExistingUnlock() {
    let state = EntitlementStore.entitlementState(
      after: .failed,
      currentState: .unlocked
    )

    XCTAssertEqual(state, .unlocked)
  }

  func testFailedInitialRefreshDoesNotGrantUnlock() {
    let state = EntitlementStore.entitlementState(
      after: .failed,
      currentState: .loading
    )

    XCTAssertEqual(state, .locked)
  }

  func testSuccessfulRefreshAppliesResolvedState() {
    let state = EntitlementStore.entitlementState(
      after: .resolved(.locked),
      currentState: .unlocked
    )

    XCTAssertEqual(state, .locked)
  }

  func testVerifiedPurchaseMayFinishAndRefreshEntitlements() {
    let resolution = EntitlementStore.purchaseResolution(for: .verified)

    XCTAssertEqual(resolution.purchaseState, .idle)
    XCTAssertTrue(resolution.shouldFinish)
    XCTAssertTrue(resolution.shouldRefreshEntitlements)
  }

  func testUnverifiedPurchaseCannotFinishOrRefreshEntitlements() {
    let resolution = EntitlementStore.purchaseResolution(for: .unverified)

    XCTAssertEqual(
      resolution.purchaseState,
      .failed("store.error.unverified_transaction")
    )
    XCTAssertFalse(resolution.shouldFinish)
    XCTAssertFalse(resolution.shouldRefreshEntitlements)
  }

  func testPendingPurchaseRemainsPending() {
    let resolution = EntitlementStore.purchaseResolution(for: .pending)

    XCTAssertEqual(resolution.purchaseState, .pending)
    XCTAssertFalse(resolution.shouldFinish)
    XCTAssertFalse(resolution.shouldRefreshEntitlements)
  }

  func testCancelledPurchaseReturnsToIdle() {
    let resolution = EntitlementStore.purchaseResolution(for: .userCancelled)

    XCTAssertEqual(resolution.purchaseState, .idle)
    XCTAssertFalse(resolution.shouldFinish)
    XCTAssertFalse(resolution.shouldRefreshEntitlements)
  }

  func testUnknownPurchaseResultUsesLocalizableFailureKey() {
    let resolution = EntitlementStore.purchaseResolution(for: .unknown)

    XCTAssertEqual(
      resolution.purchaseState,
      .failed("store.error.unknown_purchase_result")
    )
    XCTAssertFalse(resolution.shouldFinish)
    XCTAssertFalse(resolution.shouldRefreshEntitlements)
  }
}

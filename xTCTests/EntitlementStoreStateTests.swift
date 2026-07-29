import XCTest
@testable import xTC

@MainActor
final class EntitlementStoreStateTests: XCTestCase {
  func testRepeatedStartRetriesMissingProductAndRefreshesWithoutNewListener() {
    let actions = EntitlementStore.startActions(
      hasTransactionUpdatesTask: true,
      hasProduct: false
    )

    XCTAssertFalse(actions.shouldCreateTransactionUpdatesTask)
    XCTAssertTrue(actions.shouldLoadProduct)
    XCTAssertTrue(actions.shouldRefreshEntitlements)
  }

  func testRepeatedStartRefreshesEntitlementsWhenProductIsAlreadyLoaded() {
    let actions = EntitlementStore.startActions(
      hasTransactionUpdatesTask: true,
      hasProduct: true
    )

    XCTAssertFalse(actions.shouldCreateTransactionUpdatesTask)
    XCTAssertFalse(actions.shouldLoadProduct)
    XCTAssertTrue(actions.shouldRefreshEntitlements)
  }

  func testStaleRefreshGenerationCannotOverwriteNewerState() {
    let state = EntitlementStore.entitlementState(
      after: .resolved(.unlocked),
      currentState: .locked,
      refreshGeneration: 1,
      latestRefreshGeneration: 2
    )

    XCTAssertNil(state)
  }

  func testLatestRefreshGenerationAppliesResolvedState() {
    let state = EntitlementStore.entitlementState(
      after: .resolved(.locked),
      currentState: .unlocked,
      refreshGeneration: 2,
      latestRefreshGeneration: 2
    )

    XCTAssertEqual(state, .locked)
  }

  func testNonProTransactionUpdateIsIgnored() {
    XCTAssertFalse(
      EntitlementStore.shouldHandleTransactionUpdate(
        productID: "com.luoxiliu.xtc.future-product"
      )
    )
  }

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

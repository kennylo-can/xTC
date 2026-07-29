# Task 5 — Purchase and Offer Code UI Report

## Delivered

- Added `PurchaseView` with bilingual permanent-unlock copy, StoreKit localized
  pricing, purchase, restore, retry, pending, and localized error states.
- User cancellation remains a neutral idle state, as provided by
  `EntitlementStore`; the view adds no cancellation error copy.
- Purchase and restore controls are disabled while a purchase is active or
  awaiting approval.
- On macOS 15 and later, the view presents StoreKit's
  `offerCodeRedemption(isPresented:onCompletion:)` and refreshes entitlements
  after successful redemption. macOS 13–14 instead direct the customer to
  redeem through the App Store app.
- The sheet dismisses after an entitlement unlock, including when opened by an
  already unlocked user.
- Added the single `isPurchasePresented` sheet flow and a bilingual Unlock Pro
  entry point. No output pipeline behavior was changed; Task 6 owns output
  gating.
- Added deterministic language selection to `AppLanguageStore` and the brief's
  English/Chinese localization XCTest.
- Kept a `PreviewProvider` preview. This is intentionally used instead of the
  `#Preview` macro because the sandbox blocks the macro plugin process during
  command-line compilation.

## TDD evidence

1. Added `testPurchaseCopyExistsInBothLanguages` before implementation.
2. `xcodebuild build-for-testing` initially failed with the expected missing
   `AppLanguageStore.text(_:_:language:)` overload error.
3. Added the overload and verified `build-for-testing` succeeded.

## Verification

Succeeded:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build-for-testing -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /private/tmp/xtc-task5-final-build

** TEST BUILD SUCCEEDED **
```

Succeeded: a standalone Swift executable compiled from the real
`macapp/Localization.swift` and asserted English and Simplified Chinese
purchase copy selection, printing `Localization helper assertions passed`.

Blocked: the full `xcodebuild test` command builds successfully but the
sandbox denies the test runner connection to `com.apple.testmanagerd.control`
(error 159, Sandbox restriction). A direct `xctest` invocation cannot load the
app-hosted test bundle because its expected host is the Xcode agent rather than
the built app. This is an environment limitation, not a test assertion failure.

## Concerns

- No changes were made to `EntitlementStore` or the Task 6 output pipeline.
- Offer Code redemption has a macOS 15 availability guard because the installed
  StoreKit SwiftUI interface marks the modifier available from macOS 15.0.

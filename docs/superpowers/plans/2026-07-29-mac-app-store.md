# xTC Mac App Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an arm64 Mac App Store edition of xTC that previews timecode conversion for free and permanently unlocks real LTC/MTC output through one non-consumable StoreKit purchase.

**Architecture:** A focused `EntitlementStore` converts verified StoreKit 2 transactions into a single Pro entitlement. A separate `OutputAccessController` makes the free/Pro boundary testable and guards the existing MIDI and LTC output managers independently of the SwiftUI controls. A standard Xcode project builds and signs the sandboxed App Store target while the existing shell-built DMG remains available.

**Tech Stack:** Swift 5, SwiftUI, StoreKit 2, XCTest, CoreMIDI, CoreAudio, AVFAudio, C/libltc, Xcode macOS application project.

## Global Constraints

- The Mac App Store edition supports Apple Silicon (`arm64`) only.
- The deployment target is macOS 13.0 or later.
- The final app bundle identifier is `com.luoxiliu.xtc`.
- The non-consumable product identifier is `com.luoxiliu.xtc.pro`.
- Source timecode reading and converted-timecode preview remain free.
- MTC transmission and LTC audio generation require a verified Pro entitlement.
- A previously verified Pro user must remain usable while temporarily offline.
- No xTC account, developer-operated server, analytics, advertising, or telemetry is added.
- The existing DMG build remains independent and functional.
- Do not add a license-key screen, custom copy protection, or an updater to the App Store edition.

## File Structure

- `xTC.xcodeproj/project.pbxproj`: standard macOS application and test targets, build settings, sources, resources, and capabilities.
- `xTC/Info.plist`: App Store bundle metadata, microphone purpose string, and export-compliance declaration.
- `xTC/xTC.entitlements`: App Sandbox, audio input, and StoreKit-related signing entitlements.
- `xTC/Resources/PrivacyInfo.xcprivacy`: privacy manifest for an offline app with no developer data collection.
- `xTC/Resources/ThirdPartyNotices.md`: bundled libltc attribution and LGPL notice.
- `xTC/StoreKit/xTC.storekit`: local StoreKit configuration containing the permanent unlock.
- `macapp/EntitlementProviding.swift`: narrow protocol and entitlement state shared by production and tests.
- `macapp/EntitlementStore.swift`: StoreKit 2 product loading, purchase, restore, transaction updates, and verified entitlement state.
- `macapp/OutputAccessController.swift`: the testable authorization boundary that stops output when Pro access is absent or removed.
- `macapp/PurchaseView.swift`: bilingual purchase, restore, retry, and Offer Code redemption interface.
- `macapp/ContentView.swift`: free preview UI, purchase-sheet presentation, and Pro-gated output actions.
- `macapp/xTCApp.swift`: owns and injects `EntitlementStore`.
- `macapp/MIDIOutputManager.swift`: exposes a deterministic stop boundary used on entitlement loss.
- `macapp/AudioLTCOutputManager.swift`: exposes a deterministic stop boundary used on entitlement loss.
- `xTCTests/OutputAccessControllerTests.swift`: verifies free users can never activate output and entitlement loss stops output.
- `xTCTests/EntitlementStateTests.swift`: verifies transaction-to-entitlement state transitions without contacting the App Store.
- `xTCTests/TimecodePreviewTests.swift`: verifies conversion preview remains independent of Pro status.
- `docs/app-store/privacy-policy.md`: publishable bilingual privacy policy source.
- `docs/app-store/support.md`: publishable bilingual support page source.
- `docs/app-store/metadata.md`: App Store and IAP metadata, review notes, screenshot plan, and account-holder fields.
- `docs/app-store/submission-checklist.md`: exact account, StoreKit test, archive, validation, upload, Offer Code, and review steps.

---

### Task 1: Establish the App Store Xcode Build

**Files:**
- Create: `xTC.xcodeproj/project.pbxproj`
- Create: `xTC/Info.plist`
- Create: `xTC/xTC.entitlements`
- Create: `xTC/Resources/PrivacyInfo.xcprivacy`
- Create: `xTC/Resources/ThirdPartyNotices.md`
- Modify: `build-app.sh`

**Interfaces:**
- Consumes: all Swift sources in `macapp/`, the bridging header `macapp/LTCBridge.h`, `macapp/LTCBridge.c`, and C sources in `vendor/libltc/`.
- Produces: schemes `xTC` and `xTCTests`; an arm64 sandboxed Debug/Release app; `build-app.sh` remains the direct-download build.

- [ ] **Step 1: Add a smoke test that validates required project settings**

Create a temporary executable validation script at `tools/validate_app_store_project.sh`:

```bash
#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$ROOT_DIR/xTC.xcodeproj/project.pbxproj"
PLIST="$ROOT_DIR/xTC/Info.plist"
ENTITLEMENTS="$ROOT_DIR/xTC/xTC.entitlements"

grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com.luoxiliu.xtc;' "$PBXPROJ"
grep -q 'ARCHS = arm64;' "$PBXPROJ"
grep -q 'MACOSX_DEPLOYMENT_TARGET = 13.0;' "$PBXPROJ"
/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$PLIST" | grep -q false
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" | grep -q true
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS" | grep -q true
```

- [ ] **Step 2: Run the smoke test and verify it fails**

Run:

```bash
bash tools/validate_app_store_project.sh
```

Expected: FAIL because `xTC.xcodeproj/project.pbxproj` does not exist.

- [ ] **Step 3: Create the Xcode project and App Store resources**

Configure an application target named `xTC` and an XCTest target named
`xTCTests`. Add all production Swift and C files, set the bridging header to
`macapp/LTCBridge.h`, link SwiftUI, AppKit, StoreKit, CoreMIDI, CoreAudio, and
AVFAudio, and use these exact target settings:

```text
ARCHS = arm64
ONLY_ACTIVE_ARCH[Debug] = YES
MACOSX_DEPLOYMENT_TARGET = 13.0
PRODUCT_BUNDLE_IDENTIFIER = com.luoxiliu.xtc
INFOPLIST_FILE = xTC/Info.plist
CODE_SIGN_ENTITLEMENTS = xTC/xTC.entitlements
SWIFT_VERSION = 5.0
ENABLE_HARDENED_RUNTIME = YES
CODE_SIGN_STYLE = Automatic
```

Create `xTC/xTC.entitlements` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
```

Create `xTC/Info.plist` with bundle display metadata, `LSMinimumSystemVersion`
13.0, `NSMicrophoneUsageDescription`, and:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

The privacy manifest declares no tracking and no collected data. The notices
resource identifies libltc 1.3.2, its copyright holders, and LGPL-3.0-or-later.

- [ ] **Step 4: Keep the DMG build independent**

Do not redirect `build-app.sh` through Xcode. Add a comment at its header:

```bash
# Direct-download build. The Mac App Store archive is built from xTC.xcodeproj.
```

- [ ] **Step 5: Validate configuration and compile without signing**

Run:

```bash
bash tools/validate_app_store_project.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project xTC.xcodeproj -scheme xTC -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

Expected: validation succeeds and `** BUILD SUCCEEDED **` appears.

- [ ] **Step 6: Re-run the existing direct-download build**

Run:

```bash
./build-app.sh
file build/xTC.app/Contents/MacOS/xTC
```

Expected: build succeeds and the binary reports `arm64`.

- [ ] **Step 7: Commit the build foundation**

```bash
git add xTC.xcodeproj xTC tools/validate_app_store_project.sh build-app.sh
git commit -m "build: add Mac App Store Xcode target"
```

### Task 2: Model Entitlement State Before Integrating StoreKit

**Files:**
- Create: `macapp/EntitlementProviding.swift`
- Create: `xTCTests/EntitlementStateTests.swift`
- Modify: `xTC.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: no StoreKit types.
- Produces: `enum ProEntitlementState: Equatable`, `protocol EntitlementProviding: AnyObject`, and `EntitlementSnapshot.resolve(currentProductIDs:revokedProductIDs:)`.

- [ ] **Step 1: Write failing entitlement-state tests**

Create `xTCTests/EntitlementStateTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:xTCTests/EntitlementStateTests
```

Expected: FAIL because `EntitlementSnapshot` is undefined.

- [ ] **Step 3: Implement the minimum entitlement model**

Create `macapp/EntitlementProviding.swift`:

```swift
import Foundation

enum ProEntitlementState: Equatable {
  case loading
  case locked
  case unlocked
}

@MainActor
protocol EntitlementProviding: AnyObject {
  var entitlementState: ProEntitlementState { get }
  var isProUnlocked: Bool { get }
}

enum EntitlementSnapshot {
  static let proProductID = "com.luoxiliu.xtc.pro"

  static func resolve(
    currentProductIDs: Set<String>,
    revokedProductIDs: Set<String>
  ) -> ProEntitlementState {
    guard currentProductIDs.contains(proProductID),
          !revokedProductIDs.contains(proProductID) else {
      return .locked
    }
    return .unlocked
  }
}
```

- [ ] **Step 4: Run the focused tests**

Run the Task 2 test command again.

Expected: all three tests PASS.

- [ ] **Step 5: Commit the entitlement model**

```bash
git add macapp/EntitlementProviding.swift xTCTests/EntitlementStateTests.swift xTC.xcodeproj
git commit -m "test: define permanent unlock entitlement state"
```

### Task 3: Guard Real Output Independently of the UI

**Files:**
- Create: `macapp/OutputAccessController.swift`
- Create: `xTCTests/OutputAccessControllerTests.swift`
- Modify: `macapp/MIDIOutputManager.swift`
- Modify: `macapp/AudioLTCOutputManager.swift`
- Modify: `xTC.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Bool` Pro access and output closures supplied by the existing managers.
- Produces: `OutputAccessController.setUnlocked(_:)`, `requestOutput(start:) -> Bool`, and `stopAllOutput()`.

- [ ] **Step 1: Write failing authorization tests**

Create `xTCTests/OutputAccessControllerTests.swift`:

```swift
import XCTest
@testable import xTC

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
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:xTCTests/OutputAccessControllerTests
```

Expected: FAIL because `OutputAccessController` is undefined.

- [ ] **Step 3: Implement the authorization boundary**

Create `macapp/OutputAccessController.swift`:

```swift
import Foundation

@MainActor
final class OutputAccessController {
  private(set) var isUnlocked = false
  private let stopMIDI: () -> Void
  private let stopLTC: () -> Void

  init(stopMIDI: @escaping () -> Void, stopLTC: @escaping () -> Void) {
    self.stopMIDI = stopMIDI
    self.stopLTC = stopLTC
  }

  func setUnlocked(_ unlocked: Bool) {
    let lostAccess = isUnlocked && !unlocked
    isUnlocked = unlocked
    if lostAccess {
      stopAllOutput()
    }
  }

  @discardableResult
  func requestOutput(start: () -> Void) -> Bool {
    guard isUnlocked else { return false }
    start()
    return true
  }

  func stopAllOutput() {
    stopMIDI()
    stopLTC()
  }
}
```

Ensure both output managers' existing `stopClock()` and `stopOutput()` methods
are safe to call repeatedly and leave no scheduled MIDI send or audio render
running.

- [ ] **Step 4: Run authorization tests**

Run the Task 3 test command again.

Expected: all three tests PASS.

- [ ] **Step 5: Commit the output guard**

```bash
git add macapp/OutputAccessController.swift macapp/MIDIOutputManager.swift \
  macapp/AudioLTCOutputManager.swift xTCTests/OutputAccessControllerTests.swift \
  xTC.xcodeproj
git commit -m "feat: guard timecode output behind Pro access"
```

### Task 4: Implement StoreKit 2 Purchase and Restore

**Files:**
- Create: `macapp/EntitlementStore.swift`
- Create: `xTC/StoreKit/xTC.storekit`
- Modify: `macapp/xTCApp.swift`
- Modify: `xTC.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EntitlementProviding`, `EntitlementSnapshot.proProductID`, StoreKit `Product`, `Transaction.currentEntitlements`, and `Transaction.updates`.
- Produces: `EntitlementStore.shared`, `loadProduct()`, `purchase()`, `restorePurchases()`, `localizedPrice`, `purchaseState`, and published `entitlementState`.

- [ ] **Step 1: Add a local StoreKit product and launch-time test configuration**

Create `xTC/StoreKit/xTC.storekit` with one non-consumable product:

```text
Reference Name: xTC Pro Permanent Unlock
Product ID: com.luoxiliu.xtc.pro
Price: a local test price
Family Sharing: enabled for test coverage
```

Associate the StoreKit configuration with the `xTC` run and test schemes.

- [ ] **Step 2: Add the StoreKit store skeleton and verify compilation fails**

Reference `EntitlementStore` from `xTCApp.swift` before creating the file:

```swift
@StateObject private var entitlementStore = EntitlementStore()
```

Run the unsigned Xcode build from Task 1.

Expected: FAIL because `EntitlementStore` is undefined.

- [ ] **Step 3: Implement verified StoreKit state**

Create `macapp/EntitlementStore.swift` with these public types and signatures:

```swift
import StoreKit
import SwiftUI

@MainActor
final class EntitlementStore: ObservableObject, EntitlementProviding {
  enum PurchaseState: Equatable {
    case idle
    case purchasing
    case pending
    case failed(String)
  }

  @Published private(set) var entitlementState: ProEntitlementState = .loading
  @Published private(set) var product: Product?
  @Published private(set) var purchaseState: PurchaseState = .idle

  var isProUnlocked: Bool { entitlementState == .unlocked }
  var localizedPrice: String? { product?.displayPrice }

  func start() async
  func loadProduct() async
  func refreshEntitlements() async
  func purchase() async
  func restorePurchases() async
}
```

Implementation requirements:

- `loadProduct()` calls `Product.products(for:)` with only the Pro product ID.
- `refreshEntitlements()` iterates `Transaction.currentEntitlements` and counts
  only `.verified` non-revoked transactions for the Pro product.
- `purchase()` handles `.success`, `.pending`, `.userCancelled`, and unknown
  future cases; it finishes only verified transactions.
- `restorePurchases()` calls `AppStore.sync()` only after the user presses
  Restore, then refreshes entitlements.
- `start()` loads the product, refreshes local entitlements, and starts one
  retained task that listens to `Transaction.updates`.
- Error messages are bilingual-ready message keys rather than raw sensitive
  StoreKit diagnostic payloads.

- [ ] **Step 4: Inject the store into SwiftUI**

Update `xTCApp.swift`:

```swift
@StateObject private var entitlementStore = EntitlementStore()

WindowGroup {
  ContentView()
    .environmentObject(entitlementStore)
    .task { await entitlementStore.start() }
}
```

Guarantee `start()` is idempotent so scene recreation does not create duplicate
transaction-listener tasks.

- [ ] **Step 5: Compile and run the entitlement tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

Expected: all tests PASS and the StoreKit source compiles.

- [ ] **Step 6: Commit StoreKit integration**

```bash
git add macapp/EntitlementStore.swift macapp/xTCApp.swift xTC/StoreKit \
  xTC.xcodeproj
git commit -m "feat: add StoreKit permanent unlock"
```

### Task 5: Add the Purchase and Offer Code Interface

**Files:**
- Create: `macapp/PurchaseView.swift`
- Modify: `macapp/Localization.swift`
- Modify: `macapp/ContentView.swift`
- Modify: `xTC.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EntitlementStore.localizedPrice`, `purchaseState`, `purchase()`, `restorePurchases()`, and StoreKit Offer Code redemption.
- Produces: `PurchaseView` and a single `isPurchasePresented` flow used by all locked output actions.

- [ ] **Step 1: Add a failing localization-key test**

Extend `xTCTests/EntitlementStateTests.swift`:

```swift
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
```

If the current localization helper lacks the explicit `language:` overload,
the expected initial failure is a compile error for that missing overload.

- [ ] **Step 2: Implement deterministic localization for purchase UI**

Add:

```swift
static func text(
  _ english: String,
  _ chinese: String,
  language: AppLanguage
) -> String {
  language == .simplifiedChinese ? chinese : english
}
```

Keep the existing user-default-based overload delegating to this function.

- [ ] **Step 3: Build the purchase sheet**

Create `PurchaseView.swift` that:

- Uses the environment `EntitlementStore`.
- Shows “Unlock xTC Pro” / “解锁 xTC Pro”.
- Explains that real LTC and MTC output are unlocked permanently.
- Uses `localizedPrice`; never hard-codes a production price.
- Disables duplicate purchase/restore actions while an operation is active.
- Treats user cancellation as a neutral return to idle.
- Shows pending approval distinctly from failure.
- Calls `offerCodeRedemption(isPresented:onCompletion:)` on supported macOS
  versions and otherwise explains redemption through the App Store.
- Automatically dismisses once `isProUnlocked` becomes true.

- [ ] **Step 4: Present one purchase flow from all locked actions**

In `ContentView`, add:

```swift
@EnvironmentObject private var entitlementStore: EntitlementStore
@State private var isPurchasePresented = false
```

Every free-user action that would start output sets
`isPurchasePresented = true` instead. Preview mode and frame-rate selection
remain interactive.

- [ ] **Step 5: Run tests and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

Expected: tests PASS and `PurchaseView` compiles on the macOS 13 deployment
target with availability guards around newer Offer Code APIs.

- [ ] **Step 6: Commit purchase UI**

```bash
git add macapp/PurchaseView.swift macapp/Localization.swift \
  macapp/ContentView.swift xTCTests/EntitlementStateTests.swift xTC.xcodeproj
git commit -m "feat: add permanent unlock purchase flow"
```

### Task 6: Wire Pro Access Into the Live Conversion Pipeline

**Files:**
- Modify: `macapp/ContentView.swift`
- Create: `xTCTests/TimecodePreviewTests.swift`

**Interfaces:**
- Consumes: `EntitlementStore.isProUnlocked` and `OutputAccessController`.
- Produces: free conversion preview plus Pro-only calls into `MIDIOutputManager` and `AudioLTCOutputManager`.

- [ ] **Step 1: Write the free-preview regression test**

Create `xTCTests/TimecodePreviewTests.swift`:

```swift
import XCTest
@testable import xTC

final class TimecodePreviewTests: XCTestCase {
  func testConversionPreviewDoesNotRequireProEntitlement() {
    let source = TimecodeValue(hours: 1, minutes: 2, seconds: 3, frames: 12)
    let inputRate = TimecodeMath.rate(id: "25", in: TimecodeMath.outputRates)
    let outputRate = TimecodeMath.rate(id: "2997df", in: TimecodeMath.outputRates)

    let seconds = TimecodeMath.timecodeToSeconds(source, rate: inputRate)
    let preview = TimecodeMath.secondsToTimecode(seconds, rate: outputRate)

    XCTAssertEqual(TimecodeMath.format(preview), "01:02:03;14")
  }
}
```

If the exact expected frame differs according to the existing drop-frame
implementation, calculate it once from the current trusted timecode tests or
fixture and replace the literal before committing; the assertion must remain
exact rather than merely checking for a non-empty string.

- [ ] **Step 2: Run the preview and output-access tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:xTCTests/TimecodePreviewTests \
  -only-testing:xTCTests/OutputAccessControllerTests
```

Expected: preview test PASS; existing output-access tests PASS.

- [ ] **Step 3: Route every output start through authorization**

Construct `OutputAccessController` with:

```swift
stopMIDI: { midiOut.stopClock() }
stopLTC: { ltcOut.stopOutput() }
```

Update it whenever `entitlementStore.isProUnlocked` changes. Remove unconditional
output starts from `onAppear`, `updateOutputPipeline()`, output-mode changes, and
running-state changes. Keep source input monitoring active for free users.

Wrap every real output start:

```swift
let allowed = outputAccess.requestOutput {
  midiOut.startClock(rate: outputRate)
}
if !allowed {
  isPurchasePresented = true
}
```

For LTC mode use `ltcOut.startOutput(rate:)` inside the same authorization
boundary.

- [ ] **Step 4: Guard live position feeding**

At the start of `feedOutputClock()` add:

```swift
guard entitlementStore.isProUnlocked else { return }
```

Retain the `conversion` property and `outputTimecodeText` unchanged so free
preview continues updating.

- [ ] **Step 5: Make locked state visible without hiding preview**

The output panel continues showing the converted timecode. Output status and
device controls show a locked badge and an “Unlock Output” action. Do not cover,
blur, or replace the converted preview.

- [ ] **Step 6: Run the full test suite and a StoreKit manual pass**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

Then run the `xTC` scheme with `xTC.storekit` and manually verify:

1. Locked mode receives and previews timecode.
2. Locked mode emits no MTC and no LTC audio.
3. Test purchase unlocks without restart.
4. Clearing/refunding the test transaction stops output.
5. Restore re-establishes the entitlement.

- [ ] **Step 7: Commit live gating**

```bash
git add macapp/ContentView.swift xTCTests/TimecodePreviewTests.swift
git commit -m "feat: keep preview free and gate live output"
```

### Task 7: Prepare Store, Privacy, Support, and Review Materials

**Files:**
- Create: `docs/app-store/privacy-policy.md`
- Create: `docs/app-store/support.md`
- Create: `docs/app-store/metadata.md`
- Create: `docs/app-store/submission-checklist.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the final implemented feature boundary and bundle/product IDs.
- Produces: publishable bilingual copy and an account-holder checklist with no secrets.

- [ ] **Step 1: Write the bilingual privacy policy**

State exactly:

- xTC processes audio and MIDI locally.
- xTC does not record, retain, transmit, sell, or share audio, MIDI, timecode,
  device identifiers, or usage analytics.
- Apple processes App Store purchases under Apple's own policies.
- Users can contact the support address chosen by the owner.

Use `[SUPPORT_EMAIL]`, `[PRIVACY_URL]`, and `[SUPPORT_URL]` only in an explicit
“Account holder must replace before submission” table, never inside the final
copy blocks.

- [ ] **Step 2: Write the bilingual support page**

Include microphone permission steps, LTC/MTC setup, StoreKit purchase and restore
steps, Offer Code redemption, offline behavior, supported macOS/architecture,
and a diagnostic checklist that does not request private timecode content.

- [ ] **Step 3: Write exact App Store and IAP metadata**

Include:

- English and Simplified Chinese name, subtitle, description, and keywords.
- Category recommendation and rationale.
- App Privacy answers: developer collects no data.
- Non-consumable reference name, display name, description, and review notes.
- Review steps for free preview and unlocked outputs.
- Screenshot list with exact states to capture.
- Export-compliance answer matching `ITSAppUsesNonExemptEncryption = false`.
- China mainland note that the owner must answer fields shown by App Store
  Connect and may exclude that storefront until requirements are resolved.

- [ ] **Step 4: Write the account-holder submission checklist**

Give ordered checkboxes for:

1. Xcode account/team selection.
2. Bundle ID confirmation.
3. Paid Apps Agreement.
4. Banking and tax forms.
5. App record creation.
6. Non-consumable creation with exact product ID.
7. Price, tax category, availability, and optional Family Sharing.
8. StoreKit sandbox purchase and refund tests.
9. Privacy and support page publication.
10. Archive validation and upload.
11. App and first IAP joint submission.
12. Post-approval Offer Code creation for the non-consumable.

- [ ] **Step 5: Link release documentation from README**

Add a “Mac App Store” section linking the design, implementation plan, and
submission checklist. Do not replace the direct-download build instructions.

- [ ] **Step 6: Validate documentation has no unresolved submission copy**

Run:

```bash
rg -n '\\[(SUPPORT_EMAIL|PRIVACY_URL|SUPPORT_URL)\\]' docs/app-store README.md
```

Expected: matches occur only in the account-holder replacement table. Replace
each value with the owner's production contact or URL before Task 8 submission
checks, then rerun the command and expect no matches.

- [ ] **Step 7: Commit submission materials**

```bash
git add docs/app-store README.md
git commit -m "docs: prepare Mac App Store submission materials"
```

### Task 8: Validate a Distribution-Ready Archive

**Files:**
- Modify if validation finds issues: `xTC.xcodeproj/project.pbxproj`
- Modify if validation finds issues: `xTC/Info.plist`
- Modify if validation finds issues: `xTC/xTC.entitlements`
- Modify if validation finds issues: `docs/app-store/submission-checklist.md`

**Interfaces:**
- Consumes: the finished Xcode target, the owner's selected Apple Developer team, and App Store Connect configuration.
- Produces: a validated `.xcarchive` or an exact, evidence-backed list of account-bound blockers.

- [ ] **Step 1: Run all automated tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64'
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Rebuild the independent DMG edition**

Run:

```bash
./build-app.sh
./build-dmg.sh
```

Expected: both commands succeed and produce the direct-download app and DMG.

- [ ] **Step 3: Archive the App Store edition**

After the owner selects the enrolled team in Xcode, run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild archive -project xTC.xcodeproj -scheme xTC \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/xTC-AppStore.xcarchive
```

Expected: `** ARCHIVE SUCCEEDED **`. If signing assets are not yet available,
record the exact Xcode signing error as the account-bound blocker; do not replace
distribution signing with ad-hoc signing.

- [ ] **Step 4: Inspect the archived artifact**

Run:

```bash
APP="build/xTC-AppStore.xcarchive/Products/Applications/xTC.app"
file "$APP/Contents/MacOS/xTC"
codesign -dvvv --entitlements :- "$APP"
plutil -p "$APP/Contents/Info.plist"
find "$APP/Contents" -maxdepth 3 -type f -print
```

Expected:

- Binary is arm64 only.
- Signature is not ad-hoc.
- Team identifier is present.
- Sandbox and audio-input entitlements are true.
- Bundle ID is `com.luoxiliu.xtc`.
- Export-compliance flag is false.
- Privacy manifest, app icon, and third-party notices are present.

- [ ] **Step 5: Validate with Xcode Organizer or App Store Connect**

Use Xcode Organizer “Distribute App → App Store Connect → Upload” and stop before
the final upload only if the owner has not yet authorized submission. Resolve
all local validation errors. Account agreements, product metadata, or regional
questions are documented as owner actions rather than bypassed.

- [ ] **Step 6: Execute the final manual acceptance matrix**

Record results in `docs/app-store/submission-checklist.md`:

```text
Free LTC input and converted preview: PASS/FAIL
Free MTC input and converted preview: PASS/FAIL
Locked MTC produces zero output: PASS/FAIL
Locked LTC produces zero output: PASS/FAIL
Purchase unlock without restart: PASS/FAIL
Restore purchase: PASS/FAIL
Offer Code sandbox redemption: PASS/FAIL
Refund/revocation stops output: PASS/FAIL
Offline previously-owned launch: PASS/FAIL
Sandbox external/virtual device test: PASS/FAIL
```

- [ ] **Step 7: Commit final readiness fixes**

```bash
git add xTC.xcodeproj xTC docs/app-store/submission-checklist.md
git commit -m "chore: finalize Mac App Store readiness"
```

- [ ] **Step 8: Run final repository verification**

Run:

```bash
git status --short
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project xTC.xcodeproj -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64'
```

Expected: only known user-owned unrelated files remain untracked or modified,
and the test suite succeeds.

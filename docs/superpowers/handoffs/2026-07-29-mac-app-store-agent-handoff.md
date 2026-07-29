# xTC Mac App Store Agent Handoff

## Read This First

You are taking over implementation of the Mac App Store edition of xTC. The
previous controller is paused. You own implementation from the current Task 4
state onward; the original controller will review your commits rather than
write the remaining implementation.

Do not work in the repository's primary checkout. Use only:

```text
Worktree: /Users/luoxiliu/Documents/xTC/.worktrees/mac-app-store
Branch:   codex/mac-app-store
HEAD:     6b626debd913d156585eb5a4cad41c9d9a2b47d1
```

The primary checkout contains a user-owned untracked `create_dmg.sh`. It is out
of scope and must not be staged, edited, deleted, or copied into this worktree.

## Authoritative Documents

Read these completely, in order:

1. `docs/superpowers/specs/2026-07-29-mac-app-store-design.md`
2. `docs/superpowers/plans/2026-07-29-mac-app-store.md`
3. This handoff.
4. The current task brief:
   `.superpowers/sdd/2026-07-29-mac-app-store/task-4-brief.md`

If this handoff conflicts with the approved design, the approved design wins.
If the implementation plan conflicts with the approved design, stop and report
the conflict before changing code.

## Product Boundary

xTC is a free download with one permanent, non-consumable Pro unlock.

Exact product identifier:

```text
com.luoxiliu.xtc.pro
```

Free users may:

- Select and monitor LTC audio input.
- Select and monitor MTC input.
- View original timecode, detected frame rate, signal level, and state.
- Choose a target output mode and frame rate for preview.
- See the converted output timecode update in real time.
- Inspect output choices.
- Buy Pro, restore purchases, and redeem an Offer Code.

Free users must never:

- Send an MTC packet.
- Start or maintain an MTC output clock.
- Start LTC audio generation.
- Continue either output pipeline after Pro access is removed.

Pro users receive:

- Real MTC output.
- Real LTC audio output.
- Output-device selection and active synchronization.

The app remains offline-first. Do not add:

- An xTC account.
- A developer-operated server.
- Analytics, advertising, telemetry, or tracking.
- A license key screen.
- Custom copy protection.
- Continuous network validation.
- A subscription.

Temporary lack of App Store connectivity must not disable a previously verified
local entitlement.

## Platform and Distribution Boundary

The Mac App Store target:

- Supports `arm64` only.
- Requires macOS 13.0 or later.
- Uses bundle identifier `com.luoxiliu.xtc`.
- Uses App Sandbox.
- Has audio-input entitlement.
- Uses StoreKit 2.
- Declares `ITSAppUsesNonExemptEncryption = false`.

The existing direct-download shell/DMG build remains separate. Do not convert
`build-app.sh` into an Xcode wrapper and do not remove the DMG workflow.

No ICP-specific implementation is required. China mainland availability remains
an App Store Connect/account-holder decision. Do not claim a legal exemption in
code or metadata beyond the approved wording in the design.

## Completed and Reviewed Work

### Task 1 — App Store Xcode foundation

Commit:

```text
4d4c6ea44df771d6367ee7409ecf1018fee23e99
```

Implemented and independently approved:

- `xTC.xcodeproj` with app and XCTest targets/schemes.
- arm64/macOS 13 build settings.
- Info.plist, Sandbox/audio-input entitlements, privacy manifest.
- LGPL third-party notices.
- Independent direct-download build validation.

Deferred minor:

- On this host, `iconutil` rejects the generated legacy iconset.
  `build-app.sh` falls back to `AppIcon.png`, while its Info.plist still names
  `AppIcon`. The build succeeds, but Finder may not display the desired icon.
  Resolve this before final release verification without breaking the existing
  build.

### Task 2 — StoreKit-independent entitlement model

Commit:

```text
42b8e2039a4a478735a0b1a9586f63cd6eba185c
```

Implemented and independently approved:

- `ProEntitlementState`
- `EntitlementProviding`
- `EntitlementSnapshot`
- Current/missing/revoked tests

The exact product ID already lives in:

```text
macapp/EntitlementProviding.swift
```

### Task 3 — Output authorization boundary

Commit:

```text
6b626debd913d156585eb5a4cad41c9d9a2b47d1
```

Implemented and independently approved:

- `OutputAccessController`
- Locked calls cannot execute output start closures.
- Unlocked calls can execute.
- A `true → false` entitlement transition stops MIDI and LTC.
- Existing manager stop methods were inspected as repeat-safe.
- Six tests passed at this checkpoint.

`OutputAccessController` is intentionally not connected to `ContentView` yet.
That integration belongs to Task 6.

## Current In-Progress State: Task 4

The previous Task 4 implementer was interrupted at the user's request. Nothing
from Task 4 has been committed. The worktree is intentionally dirty.

Current changes:

```text
 M macapp/xTCApp.swift
 M xTC.xcodeproj/project.pbxproj
 M xTC.xcodeproj/xcshareddata/xcschemes/xTC.xcscheme
 M xTC.xcodeproj/xcshareddata/xcschemes/xTCTests.xcscheme
?? macapp/EntitlementStore.swift
?? xTC/StoreKit/
?? xTCTests/EntitlementStoreStateTests.swift
```

Do not discard or overwrite these changes blindly. Review them against the Task
4 brief first.

Recorded RED evidence:

- Adding `@StateObject private var entitlementStore = EntitlementStore()` to
  `xTCApp.swift` caused the unsigned arm64 build to fail specifically with
  `cannot find 'EntitlementStore' in scope`.

Current uncommitted implementation includes:

- One non-consumable local StoreKit product at test price `19.99`.
- English and Simplified Chinese StoreKit product localizations.
- StoreKit configuration references in app launch and test schemes.
- An `EntitlementStore` with product loading, purchase, restore, current
  entitlement refresh, and transaction update listening.
- Pure tests for refresh failure preservation and purchase-result resolution.

This implementation has not completed its GREEN verification, self-review,
commit, or independent task review. Treat it as untrusted work in progress.

Before changing it, inspect:

```bash
git diff
sed -n '1,320p' macapp/EntitlementStore.swift
sed -n '1,260p' xTCTests/EntitlementStoreStateTests.swift
plutil -lint xTC/StoreKit/xTC.storekit
```

Specific risks to review:

1. `start()` must be idempotent and retain only one `Transaction.updates`
   listener.
2. Only verified transactions may unlock or be finished.
3. An unverified transaction must never unlock Pro.
4. A verified refund/revocation must remove access.
5. A temporary refresh/verification failure must preserve an already verified
   unlocked state, but must never grant access from `.loading` or `.locked`.
6. `AppStore.sync()` must run only after an explicit Restore action.
7. User cancellation must return to idle without an error.
8. Pending purchase must remain visibly pending.
9. StoreKit errors exposed to UI must be localization keys, not raw diagnostics.
10. No purchase UI belongs in Task 4.

## Remaining Task Order

Execute tasks sequentially. Do not combine commits across review boundaries.

### Task 4 — StoreKit purchase and restore

Finish the current work using the exact Task 4 brief. Run the full test suite,
self-review, and commit:

```text
feat: add StoreKit permanent unlock
```

Then stop and provide the controller:

- Commit hash.
- RED command and expected failure.
- GREEN command and exact test summary.
- Remaining concerns.
- Path to a complete task report:
  `.superpowers/sdd/2026-07-29-mac-app-store/task-4-report.md`

Do not begin Task 5 until the controller completes independent spec and quality
review of Task 4.

### Task 5 — Purchase and Offer Code UI

Create the bilingual purchase sheet and one shared presentation path. It must
use StoreKit's localized price and support purchase, restore, retry, pending
state, and Offer Code redemption with OS availability checks.

It must never show:

- A hard-coded production price.
- A license key field.
- Raw StoreKit error payloads.

The free conversion preview must remain visible.

### Task 6 — Live pipeline gating

This is the highest-risk integration task.

Required invariants:

- Remove unconditional output startup at app/view appearance.
- Remove or guard unconditional output startup on mode/rate/running changes.
- Every real output start passes through `OutputAccessController`.
- `feedOutputClock()` returns before sending data when Pro is absent.
- Entitlement loss immediately stops both output pipelines.
- Input monitoring and conversion preview continue for free users.
- The output timecode is not blurred, hidden, or replaced by a paywall.

Tests must prove the free preview remains independent of Pro and locked users
cannot start output.

### Task 7 — Store and legal materials

Prepare bilingual privacy/support/store metadata and an exact submission
checklist. No invented URLs or email addresses may appear in final copy.

Account-holder values may be listed in a clearly marked replacement table, but
must be resolved before submission:

- Support email.
- Privacy Policy URL.
- Support URL.
- Final price.
- Storefront availability.

### Task 8 — Distribution readiness

Run tests, rebuild the direct-download app/DMG, create an arm64 archive, inspect
signature and entitlements, and record the manual acceptance matrix.

If valid distribution signing is unavailable, report the exact account-bound
blocker. Never replace App Store distribution signing with ad-hoc signing just
to make the archive step appear successful.

## TDD and Commit Rules

For every behavior change:

1. Write the focused failing test first.
2. Run it and confirm it fails for the intended missing behavior.
3. Implement the minimum code.
4. Run the focused test and full relevant suite.
5. Self-review.
6. Commit only files belonging to that task.
7. Write the task report.
8. Stop for controller review.

Do not rewrite existing commits. Do not squash reviewed task commits. Do not use
`git reset --hard`, `git checkout --`, `git clean`, or destructive commands in
this dirty worktree.

Use full Xcode paths because the active command-line developer directory may
point to CommandLineTools:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

To avoid sandbox/cache permission problems, use a task-specific DerivedData
path:

```bash
-derivedDataPath /tmp/xtc-app-store-derived-data
```

Standard test command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
  -project xTC.xcodeproj \
  -scheme xTCTests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/xtc-app-store-derived-data \
  CODE_SIGNING_ALLOWED=NO
```

Standard unsigned build command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build \
  -project xTC.xcodeproj \
  -scheme xTC \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/xtc-app-store-derived-data \
  CODE_SIGNING_ALLOWED=NO
```

Keep test/build logs concise in chat, but preserve exact commands and result
summaries in each task report.

## Review Contract

After each task, the original controller will review rather than implement.

The implementer must provide:

- One task-scoped commit.
- A report file under the plan's `.superpowers/sdd` workspace.
- RED and GREEN evidence.
- Test count and failure count.
- Concerns and account-bound blockers.

The controller will check:

- Compliance with the task brief and approved product boundary.
- No accidental network/account/telemetry additions.
- Entitlement and output safety.
- Error and offline behavior.
- Test quality.
- Scope discipline.

Critical or Important findings return to the implementer for correction.
Minor findings may be recorded for final whole-branch review.

## Account-Holder Boundary

The implementation agent must not request, store, print, or commit:

- Apple Account passwords.
- Two-factor authentication codes.
- Certificate private keys.
- App Store Connect API keys.
- In-App Purchase private keys.
- Banking or tax information.

The repository can prepare code and instructions. The owner must personally:

- Sign in to Xcode.
- Select the enrolled developer team.
- Confirm/register the Bundle ID.
- Accept the Paid Apps Agreement.
- Complete tax and banking information.
- Create the production non-consumable using the exact product ID.
- Choose final price and storefronts.
- Publish real privacy/support URLs.
- Approve signing assets.
- Upload and submit the app and first In-App Purchase.
- Create production Offer Codes after approval.

If an action requires these credentials or legal confirmations, stop at a clear
checkpoint and give the owner exact UI steps. Do not invent success.

## Definition of Done

The project is ready to hand to the owner for final App Store submission only
when:

- All eight plan tasks are complete and reviewed.
- All automated tests pass.
- Free LTC/MTC input and converted preview work.
- Locked mode emits zero MTC and zero LTC audio.
- Purchase unlocks without restart.
- Restore and Offer Code redemption use the same Pro entitlement.
- Refund/revocation stops output.
- Previously verified Pro works offline.
- Sandbox audio/MIDI device tests are recorded.
- The direct-download build still works.
- The arm64 archive is inspected and valid, or the sole remaining blocker is
  explicitly account-bound.
- Privacy, support, metadata, notices, and submission instructions contain no
  unresolved production placeholders.


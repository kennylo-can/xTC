# Task 6 Report: Free Preview With Pro-Only Live Output

## Delivered

- Kept LTC/MTC input monitoring and the raw plus converted timecode preview
  independent of Pro entitlement.
- Added one persistent `LiveOutputPipeline` that constructs and owns the
  existing `OutputAccessController`.
- Routed every live MTC/LTC start and position submission through
  `requestOutput(start:)`.
- Synced `EntitlementStore.isProUnlocked` on appearance and every entitlement
  change. Losing an entitlement immediately invokes both repeat-safe stop
  closures; regaining it restarts only the currently selected output while the
  converter is running.
- Added an entitlement guard at the start of `feedOutputClock()`.
- Removed the duplicate unconditional MTC start on appearance and all other
  unconditional output starts from mode/running transitions.
- Added locked output status and locked device-control rows with bilingual
  `Unlock Output` actions. The converted output timecode remains visible and
  unchanged.
- Registered `TimecodePreviewTests.swift` in the manually maintained Xcode
  project test target.

No StoreKit product, transaction, purchase, restore, or offer-code semantics
were changed.

## TDD Evidence

1. Added the brief's exact free-preview regression before production changes.
   The existing conversion implementation compiled successfully.
2. Added missing live-integration tests for locked MTC/LTC starts, locked
   position submission, and entitlement-loss shutdown.
3. Observed RED from `build-for-testing`: `cannot find type
   'LiveOutputPipeline' in scope`.
4. Added the minimal live output boundary and observed GREEN from
   `build-for-testing`.
5. The first runtime preview assertion exposed the brief's anticipated
   drop-frame fixture difference: the existing implementation produced
   `01:02:03;15`, not `01:02:03;14`. The exact literal was corrected after a
   hand calculation (93087 source frames / 25 fps, mapped to 111593 rounded
   29.97 DF actual frames). No production timecode logic changed.

## Verification

Succeeded:

```text
xcodebuild build-for-testing ... -derivedDataPath /private/tmp/xtc-task6-final-build-for-testing
** TEST BUILD SUCCEEDED **
```

```text
xcodebuild build ... -derivedDataPath /private/tmp/xtc-task6-final-build
** BUILD SUCCEEDED **
```

The focused preview/output-access matrix passed 7 tests with 0 failures.

The full suite passed outside the restricted test-runner sandbox:

```text
Test Suite 'xTCTests.xctest' passed
Executed 24 tests, with 0 failures
** TEST SUCCEEDED **
```

The same test command inside the restricted sandbox built the test bundle but
could not connect to `com.apple.testmanagerd.control` (error 159). Running with
the approved test-runner permission resolved that environmental restriction.

## Requirement Audit

- Locked MTC start: rejected and tested.
- Locked LTC start: rejected and tested.
- Locked MTC/LTC position submission: rejected and tested.
- Entitlement loss: both output pipelines stopped and tested.
- Free conversion preview: exact output tested.
- Input monitoring and preview: no entitlement guard added.
- Converted preview visibility: retained in the output panel for locked users.
- StoreKit semantics: untouched.

## Concerns

- The interactive `xTC.storekit` purchase, refund/clear, and restore pass
  requires a human-driven StoreKit test session and was not performed in this
  non-interactive task run.
- Existing CoreAudio HAL and vendor `libltc` warnings remain visible during
  command-line builds; they did not prevent the app build or 24-test suite.

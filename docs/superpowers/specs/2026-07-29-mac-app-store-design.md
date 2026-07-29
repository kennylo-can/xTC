# xTC Mac App Store Design

## Goal

Ship a Mac App Store edition of xTC as a free, offline-first macOS app with a
single non-consumable StoreKit purchase that permanently unlocks real LTC and
MTC output.

The free edition must remain genuinely useful: it can receive LTC or MTC,
display the source timecode and signal state, select a target frame rate, and
show the converted timecode in real time. It must not transmit MTC or generate
LTC audio until the permanent unlock is active.

The existing direct-download DMG workflow remains separate. The Mac App Store
edition supports Apple Silicon (`arm64`) only and requires macOS 13 or later.

## Product Model

The app download is free. One non-consumable In-App Purchase unlocks all
professional output functionality permanently.

- Reference name: xTC Pro Permanent Unlock
- Product ID: `com.luoxiliu.xtc.pro`
- Type: Non-Consumable
- Unlocks: MTC output, LTC audio output, output-device controls, and active
  synchronization to an output
- Does not require: an xTC account, a developer-operated server, a subscription,
  or continuous network access

The product identifier is treated as permanent after it is created in App
Store Connect.

Offer Codes configured for this product may grant a free permanent unlock.
Normal purchases, restored purchases, Family Sharing transactions when enabled,
and Offer Code redemptions all produce the same local Pro entitlement.

## Free and Pro Boundaries

### Free

- Select and monitor an LTC audio input.
- Select and monitor an MTC input.
- Display source timecode, detected frame rate, signal level, and status.
- Select the output mode and target frame rate for preview purposes.
- Calculate and display the converted output timecode in real time.
- Inspect available output choices without transmitting output.
- Open the purchase sheet, restore purchases, and redeem an Offer Code.

### Pro

- Send converted MTC to a selected MIDI destination.
- Generate converted LTC audio on a selected audio output.
- Start and stop active output synchronization.
- Persist and restore the selected real output devices.

Changing preview settings is free. Any action that would start an output
pipeline, transmit a MIDI packet, or generate LTC audio requires a verified Pro
entitlement.

## Architecture

### StoreKit entitlement layer

Create an `EntitlementStore` owned by the SwiftUI app and injected into the
view hierarchy. It has one responsibility: turn verified StoreKit transactions
into a simple entitlement state the rest of the app can consume.

It will:

- Load the configured product and its localized price.
- Read current entitlements at launch.
- Listen continuously for transaction updates.
- Purchase the permanent unlock.
- Restore purchases using App Store synchronization after explicit user action.
- Finish verified transactions.
- Reject unverified, revoked, or refunded transactions.
- Expose loading, available, purchased, and recoverable-error states.

No private key, shared secret, receipt payload, or developer credential is
stored in the repository or application bundle.

### Output authorization

Create a small output-authorization boundary between the UI and the existing
`MIDIOutputManager` and `AudioLTCOutputManager`.

The UI may calculate and display conversion previews without authorization.
The output managers may start or receive converted positions only when
`isProUnlocked` is true. Entitlement loss immediately stops both output
pipelines. This manager-level guard is required in addition to disabled UI so
that later UI changes cannot accidentally transmit output for free users.

### Purchase interface

Present a compact bilingual purchase sheet when a free user performs an output
action. It shows:

- Permanent-unlock value proposition.
- StoreKit-provided localized price.
- Purchase button.
- Restore Purchases button.
- Redeem Offer Code button when the OS supports in-app redemption.
- Links to the privacy policy and support page.
- Clear progress, cancellation, pending, and recoverable-error states.

The sheet never shows a license-key field. If StoreKit cannot load, free preview
continues to work and the sheet offers a retry.

## Offline Behavior

The application derives Pro access from StoreKit's locally available verified
transactions. It does not require an xTC server.

- A previously verified owner can use Pro output while temporarily offline.
- A new purchase, restore, or Offer Code redemption requires App Store
  connectivity.
- A transient StoreKit failure does not erase a previously established current
  entitlement.
- A verified revocation or refund removes Pro access and stops active output.

## Mac App Store Target

Create a standard Xcode macOS application project that uses the existing Swift
and C sources. The target:

- Builds `arm64` only.
- Targets macOS 13 or later.
- Uses bundle identifier `com.luoxiliu.xtc`.
- Uses automatic signing with the owner's Apple Developer team.
- Enables App Sandbox.
- Enables audio input access.
- Enables In-App Purchase.
- Includes the microphone usage description.
- Declares `ITSAppUsesNonExemptEncryption` as false because this edition does
  not implement non-exempt encryption.
- Contains a valid app icon, version, build number, third-party notices, and any
  required privacy manifest.

Core Audio and CoreMIDI behavior must be verified in a sandboxed build with
built-in and available external or virtual devices before submission.

The existing shell/DMG distribution path is not converted into the App Store
artifact and must continue to build independently.

## Privacy and Compliance

xTC does not include networking, analytics, advertising, accounts, telemetry,
or developer-operated data collection. App Store privacy answers will state
that the developer does not collect data, subject to a final source and binary
audit before submission.

A public privacy policy and support page are still required. They will explain
that audio and MIDI are processed locally, no recordings or timecode data are
uploaded, and purchases are processed by Apple.

The app includes LGPL-licensed libltc-derived source. The distribution must
include the applicable license and third-party attribution, and the final
packaging review must verify compliance with the library's relinking/source
requirements.

China mainland availability will be configured only after App Store Connect
shows which regional filing fields apply. The application has no internet
content service, but the submission will not claim a filing exemption beyond
what App Store Connect and applicable rules permit.

## App Review and Store Configuration

Prepare:

- Simplified Chinese and English app name, subtitle, description, keywords, and
  release notes.
- macOS screenshots showing free preview and Pro output.
- Privacy Policy URL and Support URL.
- App Privacy and age-rating answers.
- Review notes explaining how to test LTC and MTC input without specialized
  studio equipment where possible.
- A review screenshot and metadata for the non-consumable product.
- StoreKit configuration for local tests.
- Paid Apps Agreement, tax, banking, price, availability, and tax category
  checklist for the account holder.
- Offer Code and optional Family Sharing setup instructions.

The first In-App Purchase is submitted with the app version for review.

## Error Handling

- Product unavailable: retain free preview, explain that the store is
  temporarily unavailable, and provide retry.
- User cancellation: close progress state without treating it as an error.
- Pending purchase: show that approval is pending and keep free mode active.
- Unverified transaction: do not unlock; record a non-sensitive diagnostic and
  show a support-oriented error.
- Restore finds no entitlement: explain that no eligible purchase was found.
- Entitlement removed while output is active: stop MIDI and LTC output
  immediately and return to preview mode.
- Output hardware disappears: stop only the affected pipeline and preserve the
  Pro entitlement.

## Testing and Acceptance

The implementation is ready for App Store submission when:

1. Free users can receive LTC and MTC and see source and converted timecode.
2. No MIDI packet or LTC audio is emitted without a verified Pro entitlement.
3. StoreKit test purchase unlocks both output modes without restarting.
4. Purchase cancellation, pending approval, failure, restore, refund, and
   transaction updates produce the intended state.
5. Offer Code redemption is reflected through the same entitlement path.
6. A previously verified Pro user can launch and output while offline.
7. Sandbox audio input, audio output, MIDI input, and MIDI output work on
   available real or virtual devices.
8. The arm64 Release archive passes Xcode validation with the distribution
   profile and intended entitlements.
9. The existing DMG build remains functional.
10. Store metadata, privacy answers, policy pages, third-party notices, and
    review instructions contain no placeholders and match the shipped build.

## Account-Holder Checkpoints

The repository can prepare the project and submission materials, but the owner
must perform or approve these account-bound actions:

- Sign in to Xcode with the enrolled Apple Account and select the developer
  team.
- Confirm or register the final bundle identifier.
- Accept the Paid Apps Agreement and complete tax and banking details.
- Create the non-consumable product with the exact product identifier.
- Choose the selling price and storefront availability.
- Supply final public Privacy Policy and Support URLs.
- Approve certificate/profile creation.
- Upload the archive, answer export-compliance and regional questions, and
  submit the app and In-App Purchase to App Review.


import StoreKit
import SwiftUI

struct PurchaseView: View {
  @EnvironmentObject private var entitlementStore: EntitlementStore
  @Environment(\.dismiss) private var dismiss
  @AppStorage(AppLanguageStore.storageKey) private var languageRaw = AppLanguage.english.rawValue

  @State private var isOfferCodeRedemptionPresented = false
  @State private var offerCodeError: String?

  private var language: AppLanguage {
    AppLanguage(rawValue: languageRaw) ?? .english
  }

  private var isOperationActive: Bool {
    switch entitlementStore.purchaseState {
    case .purchasing, .pending:
      return true
    case .idle, .failed:
      return false
    }
  }

  private func t(_ english: String, _ chinese: String) -> String {
    AppLanguageStore.text(english, chinese, language: language)
  }

  var body: some View {
    offerCodeAwareContent
      .frame(width: 420)
      .padding(28)
      .onAppear {
        if entitlementStore.isProUnlocked {
          dismiss()
        }
      }
      .onChange(of: entitlementStore.isProUnlocked) { isUnlocked in
        if isUnlocked {
          dismiss()
        }
      }
  }

  @ViewBuilder
  private var offerCodeAwareContent: some View {
    if #available(macOS 15.0, *) {
      purchaseContent
        .offerCodeRedemption(
          isPresented: $isOfferCodeRedemptionPresented,
          onCompletion: completeOfferCodeRedemption
        )
    } else {
      purchaseContent
    }
  }

  private var purchaseContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text(t("Unlock xTC Pro", "解锁 xTC Pro"))
          .font(.title2.weight(.bold))

        Text(
          t(
            "Unlock real LTC audio and MTC output permanently. Timecode reading and preview stay available to everyone.",
            "永久解锁真实 LTC 音频和 MTC 输出。时间码读取与预览始终免费可用。"
          )
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      purchaseStateMessage

      Button(action: beginPurchase) {
        if case .purchasing = entitlementStore.purchaseState {
          ProgressView()
            .controlSize(.small)
        } else {
          Text(purchaseButtonTitle)
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(isOperationActive)

      HStack {
        Button(t("Restore Purchases", "恢复购买"), action: restorePurchases)
          .disabled(isOperationActive)

        Spacer()

        offerCodeControl
      }

      if case .failed = entitlementStore.purchaseState {
        Button(t("Retry", "重试"), action: beginPurchase)
          .disabled(isOperationActive)
      }

      if let offerCodeError {
        Text(offerCodeError)
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var offerCodeControl: some View {
    if #available(macOS 15.0, *) {
      Button(t("Redeem Offer Code", "兑换优惠代码")) {
        offerCodeError = nil
        isOfferCodeRedemptionPresented = true
      }
      .disabled(isOperationActive)
    } else {
      Text(t("Redeem offer codes in the App Store app.", "请在 App Store 应用中兑换优惠代码。"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  @ViewBuilder
  private var purchaseStateMessage: some View {
    switch entitlementStore.purchaseState {
    case .idle:
      EmptyView()
    case .purchasing:
      Label(t("Contacting the App Store…", "正在连接 App Store…"), systemImage: "arrow.triangle.2.circlepath")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    case .pending:
      Label(t("Purchase approval is pending.", "购买正在等待批准。"), systemImage: "clock.badge.exclamationmark")
        .font(.subheadline)
        .foregroundStyle(.orange)
    case .failed(let key):
      Label(purchaseFailureMessage(for: key), systemImage: "exclamationmark.triangle.fill")
        .font(.subheadline)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var purchaseButtonTitle: String {
    let price = entitlementStore.localizedPrice
      ?? t("Loading price…", "正在加载价格…")
    return "\(t("Unlock permanently", "永久解锁")) — \(price)"
  }

  private func purchaseFailureMessage(for key: String) -> String {
    switch key {
    case "store.error.product_unavailable":
      return t("The permanent unlock is currently unavailable.", "永久解锁当前不可用。")
    case "store.error.product_load_failed":
      return t("The App Store product could not be loaded.", "无法加载 App Store 产品。")
    case "store.error.purchase_failed":
      return t("The purchase could not be completed. Please try again.", "无法完成购买，请重试。")
    case "store.error.restore_not_found":
      return t("No previous permanent unlock was found for this Apple Account.", "此 Apple 账户未找到先前的永久解锁。")
    case "store.error.restore_failed":
      return t("Purchases could not be restored. Please try again.", "无法恢复购买，请重试。")
    case "store.error.unverified_transaction":
      return t("The transaction could not be verified.", "无法验证该交易。")
    default:
      return t("The purchase result was not recognized. Please try again.", "无法识别购买结果，请重试。")
    }
  }

  private func beginPurchase() {
    Task {
      await entitlementStore.purchase()
    }
  }

  private func restorePurchases() {
    Task {
      await entitlementStore.restorePurchases()
    }
  }

  @available(macOS 15.0, *)
  private func completeOfferCodeRedemption(_ result: Result<Void, Error>) {
    switch result {
    case .success:
      Task {
        await entitlementStore.refreshEntitlements()
      }
    case .failure:
      offerCodeError = t(
        "The offer code could not be redeemed. Please try again.",
        "无法兑换优惠代码，请重试。"
      )
    }
  }
}

struct PurchaseView_Previews: PreviewProvider {
  static var previews: some View {
    PurchaseView()
      .environmentObject(EntitlementStore.shared)
  }
}

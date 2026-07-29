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

  enum EntitlementRefreshOutcome: Equatable {
    case resolved(ProEntitlementState)
    case failed
  }

  enum PurchaseOutcome {
    case verified
    case unverified
    case pending
    case userCancelled
    case unknown
  }

  struct PurchaseResolution {
    let purchaseState: PurchaseState
    let shouldFinish: Bool
    let shouldRefreshEntitlements: Bool
  }

  static let shared = EntitlementStore()

  @Published private(set) var entitlementState: ProEntitlementState = .loading
  @Published private(set) var product: Product?
  @Published private(set) var purchaseState: PurchaseState = .idle

  var isProUnlocked: Bool {
    entitlementState == .unlocked
  }

  var localizedPrice: String? {
    product?.displayPrice
  }

  private var transactionUpdatesTask: Task<Void, Never>?

  deinit {
    transactionUpdatesTask?.cancel()
  }

  func start() async {
    guard transactionUpdatesTask == nil else {
      return
    }

    transactionUpdatesTask = Task { [weak self] in
      for await verificationResult in StoreKit.Transaction.updates {
        guard !Task.isCancelled else {
          return
        }
        await self?.handle(transactionUpdate: verificationResult)
      }
    }

    async let productLoad: Void = loadProduct()
    async let entitlementRefresh: Void = refreshEntitlements()
    _ = await (productLoad, entitlementRefresh)
  }

  func loadProduct() async {
    do {
      let products = try await Product.products(
        for: [EntitlementSnapshot.proProductID]
      )
      guard let loadedProduct = products.first(
        where: { $0.id == EntitlementSnapshot.proProductID }
      ) else {
        purchaseState = .failed("store.error.product_unavailable")
        return
      }

      product = loadedProduct
      if case .failed = purchaseState {
        purchaseState = .idle
      }
    } catch {
      purchaseState = .failed("store.error.product_load_failed")
    }
  }

  func refreshEntitlements() async {
    var currentProductIDs = Set<String>()
    var revokedProductIDs = Set<String>()
    var encounteredUnverifiedProTransaction = false

    for await verificationResult in StoreKit.Transaction.currentEntitlements {
      switch verificationResult {
      case .verified(let transaction):
        guard transaction.productID == EntitlementSnapshot.proProductID else {
          continue
        }

        if transaction.revocationDate == nil {
          currentProductIDs.insert(transaction.productID)
        } else {
          revokedProductIDs.insert(transaction.productID)
        }
      case .unverified(let transaction, _):
        if transaction.productID == EntitlementSnapshot.proProductID {
          encounteredUnverifiedProTransaction = true
        }
      }
    }

    let outcome: EntitlementRefreshOutcome
    if encounteredUnverifiedProTransaction,
       currentProductIDs.isEmpty,
       revokedProductIDs.isEmpty {
      outcome = .failed
    } else {
      outcome = .resolved(
        EntitlementSnapshot.resolve(
          currentProductIDs: currentProductIDs,
          revokedProductIDs: revokedProductIDs
        )
      )
    }

    entitlementState = Self.entitlementState(
      after: outcome,
      currentState: entitlementState
    )
  }

  func purchase() async {
    if product == nil {
      await loadProduct()
    }

    guard let product else {
      purchaseState = .failed("store.error.product_unavailable")
      return
    }

    purchaseState = .purchasing

    do {
      switch try await product.purchase() {
      case .success(.verified(let transaction)):
        await apply(
          purchaseResolution: Self.purchaseResolution(for: .verified),
          verifiedTransaction: transaction
        )
      case .success(.unverified):
        await apply(
          purchaseResolution: Self.purchaseResolution(for: .unverified)
        )
      case .pending:
        await apply(
          purchaseResolution: Self.purchaseResolution(for: .pending)
        )
      case .userCancelled:
        await apply(
          purchaseResolution: Self.purchaseResolution(for: .userCancelled)
        )
      @unknown default:
        await apply(
          purchaseResolution: Self.purchaseResolution(for: .unknown)
        )
      }
    } catch {
      purchaseState = .failed("store.error.purchase_failed")
    }
  }

  func restorePurchases() async {
    purchaseState = .purchasing

    do {
      try await AppStore.sync()
      await refreshEntitlements()
      purchaseState = isProUnlocked
        ? .idle
        : .failed("store.error.restore_not_found")
    } catch {
      purchaseState = .failed("store.error.restore_failed")
    }
  }

  static func entitlementState(
    after outcome: EntitlementRefreshOutcome,
    currentState: ProEntitlementState
  ) -> ProEntitlementState {
    switch outcome {
    case .resolved(let state):
      return state
    case .failed:
      return currentState == .unlocked ? .unlocked : .locked
    }
  }

  static func purchaseResolution(
    for outcome: PurchaseOutcome
  ) -> PurchaseResolution {
    switch outcome {
    case .verified:
      return PurchaseResolution(
        purchaseState: .idle,
        shouldFinish: true,
        shouldRefreshEntitlements: true
      )
    case .unverified:
      return PurchaseResolution(
        purchaseState: .failed("store.error.unverified_transaction"),
        shouldFinish: false,
        shouldRefreshEntitlements: false
      )
    case .pending:
      return PurchaseResolution(
        purchaseState: .pending,
        shouldFinish: false,
        shouldRefreshEntitlements: false
      )
    case .userCancelled:
      return PurchaseResolution(
        purchaseState: .idle,
        shouldFinish: false,
        shouldRefreshEntitlements: false
      )
    case .unknown:
      return PurchaseResolution(
        purchaseState: .failed("store.error.unknown_purchase_result"),
        shouldFinish: false,
        shouldRefreshEntitlements: false
      )
    }
  }

  private func apply(
    purchaseResolution: PurchaseResolution,
    verifiedTransaction: StoreKit.Transaction? = nil
  ) async {
    purchaseState = purchaseResolution.purchaseState

    if purchaseResolution.shouldFinish {
      await verifiedTransaction?.finish()
    }
    if purchaseResolution.shouldRefreshEntitlements {
      await refreshEntitlements()
    }
  }

  private func handle(
    transactionUpdate: VerificationResult<StoreKit.Transaction>
  ) async {
    switch transactionUpdate {
    case .verified(let transaction):
      await refreshEntitlements()
      await transaction.finish()
    case .unverified:
      purchaseState = .failed("store.error.unverified_transaction")
    }
  }
}

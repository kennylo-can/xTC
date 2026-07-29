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

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

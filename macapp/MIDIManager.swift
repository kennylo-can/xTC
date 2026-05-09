import Foundation
import CoreMIDI

struct MIDISourceItem: Identifiable, Hashable {
  let id: Int32
  let name: String
}

@MainActor
final class MIDIManager: ObservableObject {
  @Published var sources: [MIDISourceItem] = []
  @Published var selectedSourceID: Int32?
  @Published var listeningState: String = AppLanguageStore.text("Disconnected", "未连接")
  @Published var detectedRate: FrameRateOption?
  @Published var receivedTimecode: TimecodeValue?
  @Published var lastReceivedAt: Date?
  @Published var latencyEstimateMs: Double?
  @Published var lastMessage: String = AppLanguageStore.text("Waiting for MTC input", "等待 MTC 输入")

  private var client = MIDIClientRef()
  private var inputPort = MIDIPortRef()
  private var connectedSource: MIDIEndpointRef?

  // Quarter-frame accumulation — only accessed from MainActor
  private var quarterFrames: [UInt8?] = Array(repeating: nil, count: 8)

  init() {
    setupClient()
    refreshSources()
    if let first = sources.first {
      selectedSourceID = first.id
    }
  }

  func refreshSources() {
    var items: [MIDISourceItem] = []
    let count = MIDIGetNumberOfSources()
    for index in 0..<count {
      let endpoint = MIDIGetSource(index)
      guard endpoint != 0 else { continue }
      let uid = uniqueID(for: endpoint)
      let name = displayName(for: endpoint)
      items.append(MIDISourceItem(id: uid, name: name))
    }
    sources = items
    // Preserve selection if still available; fall back to first
    if let current = selectedSourceID, !items.contains(where: { $0.id == current }) {
      selectedSourceID = items.first?.id
    } else if selectedSourceID == nil {
      selectedSourceID = items.first?.id
    }
  }

  func connectSelectedSource() {
    disconnect()
    guard let selectedSourceID,
          let endpoint = sourceEndpoint(forUniqueID: selectedSourceID)
    else {
      listeningState = AppLanguageStore.text("No MIDI input available", "没有可用的 MIDI 输入")
      return
    }

    let status = MIDIPortConnectSource(inputPort, endpoint, Unmanaged.passUnretained(self).toOpaque())
    guard status == noErr else {
      listeningState = AppLanguageStore.text("Connection failed", "连接失败") + ": \(status)"
      return
    }

    connectedSource = endpoint
    listeningState = AppLanguageStore.text("Monitoring", "正在监听") + " \(displayName(for: endpoint))"
  }

  func disconnect() {
    if let endpoint = connectedSource {
      MIDIPortDisconnectSource(inputPort, endpoint)
      connectedSource = nil
    }
    listeningState = AppLanguageStore.text("Disconnected", "未连接")
  }

  func clear() {
    quarterFrames = Array(repeating: nil, count: 8)
    detectedRate = nil
    receivedTimecode = nil
    latencyEstimateMs = nil
    lastMessage = AppLanguageStore.text("Waiting for MTC input", "等待 MTC 输入")
  }

  // MARK: - MIDI Client Setup

  private func setupClient() {
    // Notify block handles hot-plug: refresh sources on any MIDI topology change
    let createStatus = MIDIClientCreateWithBlock("xTCClient" as CFString, &client) { [weak self] notification in
      let msgID = notification.pointee.messageID
      if msgID == .msgObjectAdded || msgID == .msgObjectRemoved || msgID == .msgSetupChanged {
        Task { @MainActor [weak self] in
          self?.refreshSources()
        }
      }
    }
    guard createStatus == noErr else {
      listeningState = AppLanguageStore.text("Unable to create MIDI client", "无法创建 MIDI Client") + ": \(createStatus)"
      return
    }

    // Input port: extract packet bytes on the CoreMIDI thread (pointer only valid there),
    // then dispatch handling to MainActor so all @Published mutations are actor-isolated.
    let portStatus = MIDIInputPortCreateWithBlock(client, "xTCInput" as CFString, &inputPort) { [weak self] packetList, _ in
      let extracted = MIDIManager.extractPackets(from: packetList)
      Task { @MainActor [weak self] in
        for bytes in extracted {
          self?.process(bytes: bytes)
        }
      }
    }
    guard portStatus == noErr else {
      listeningState = AppLanguageStore.text("Unable to create MIDI input port", "无法创建 MIDI Input Port") + ": \(portStatus)"
      return
    }
  }

  // MARK: - Packet extraction (called on CoreMIDI thread — must be static/nonisolated)

  private static func extractPackets(from packetList: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
    var result: [[UInt8]] = []
    let pointer = UnsafeMutablePointer(mutating: packetList)
    var packet = pointer.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
      let bytes = withUnsafeBytes(of: packet.data) { rawBuffer in
        Array(rawBuffer.prefix(Int(packet.length)))
      }
      result.append(bytes)
      packet = MIDIPacketNext(&packet).pointee
    }
    return result
  }

  // MARK: - Packet processing (MainActor)

  private func process(bytes: [UInt8]) {
    guard let status = bytes.first else { return }

    switch status {
    case 0xF1 where bytes.count >= 2:
      let data = bytes[1]
      let piece = Int(data >> 4)
      guard piece < 8 else { return }
      quarterFrames[piece] = data & 0x0f
      if piece == 7 {
        decodeQuarterFrames()
      }

    case 0xF0:
      guard bytes.count >= 10,
            bytes[1] == 0x7f,
            bytes[2] == 0x7f,
            bytes[3] == 0x01,
            bytes[4] == 0x01,
            bytes.last == 0xf7
      else { return }
      decodeFullFrame(bytes)

    default:
      break
    }
  }

  private func decodeQuarterFrames() {
    guard quarterFrames.allSatisfy({ $0 != nil }),
          let f0 = quarterFrames[0], let f1 = quarterFrames[1],
          let f2 = quarterFrames[2], let f3 = quarterFrames[3],
          let f4 = quarterFrames[4], let f5 = quarterFrames[5],
          let f6 = quarterFrames[6], let f7 = quarterFrames[7]
    else { return }

    var frames  = Int(f0) | (Int(f1 & 0x01) << 4)
    var seconds = Int(f2) | (Int(f3 & 0x03) << 4)
    var minutes = Int(f4) | (Int(f5 & 0x03) << 4)
    var hours   = Int(f6) | (Int(f7 & 0x01) << 4)
    let rateCode = Int((f7 >> 1) & 0x03)

    guard let rate = TimecodeMath.inputRates.first(where: { $0.mtcRateCode == rateCode && !$0.dropFrame }) ??
                     TimecodeMath.inputRates.first(where: { $0.mtcRateCode == rateCode })
    else { return }

    // MTC Quarter Frame protocol: the decoded TC lags 2 frames behind the actual position
    // (f0..f7 spans 2 video frames). Compensate by adding 2 frames.
    let nominalFPS = rate.nominalFrameCount
    frames += 2
    if frames >= nominalFPS {
      frames -= nominalFPS
      seconds += 1
      if seconds >= 60 {
        seconds = 0
        minutes += 1
        if minutes >= 60 {
          minutes = 0
          hours = min(hours + 1, 23)
        }
      }
    }

    let tc = TimecodeValue(
      negative: false,
      hours: hours, minutes: minutes, seconds: seconds, frames: frames,
      delimiter: rate.dropFrame ? ";" : ":"
    )

    detectedRate = rate
    receivedTimecode = tc
    lastReceivedAt = Date()
    latencyEstimateMs = 0.5
    lastMessage = AppLanguageStore.text("Quarter Frame", "Quarter Frame")
    listeningState = AppLanguageStore.text("Received MTC", "收到 MTC") + " \(rate.label)"
  }

  private func decodeFullFrame(_ bytes: [UInt8]) {
    guard bytes.count >= 10 else { return }
    let rateCode = Int((bytes[5] >> 5) & 0x03)
    let hours    = Int(bytes[5] & 0x1f)
    let minutes  = Int(bytes[6] & 0x3f)
    let seconds  = Int(bytes[7] & 0x3f)
    let frames   = Int(bytes[8] & 0x1f)

    guard let rate = TimecodeMath.inputRates.first(where: { $0.mtcRateCode == rateCode && !$0.dropFrame }) ??
                     TimecodeMath.inputRates.first(where: { $0.mtcRateCode == rateCode })
    else { return }

    let tc = TimecodeValue(
      negative: false,
      hours: hours, minutes: minutes, seconds: seconds, frames: frames,
      delimiter: rate.dropFrame ? ";" : ":"
    )

    detectedRate = rate
    receivedTimecode = tc
    lastReceivedAt = Date()
    latencyEstimateMs = 0.2
    lastMessage = AppLanguageStore.text("Full Frame", "Full Frame")
    listeningState = AppLanguageStore.text("Received MTC", "收到 MTC") + " \(rate.label)"

    // Full Frame is a locate/jump event — reset QF accumulator
    quarterFrames = Array(repeating: nil, count: 8)
  }

  // MARK: - CoreMIDI helpers

  private func uniqueID(for endpoint: MIDIEndpointRef) -> Int32 {
    var uid: Int32 = 0
    MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
    return uid
  }

  private func displayName(for endpoint: MIDIEndpointRef) -> String {
    var cfName: Unmanaged<CFString>?
    if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cfName) == noErr,
       let name = cfName?.takeRetainedValue() as String? {
      return name
    }
    if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName) == noErr,
       let name = cfName?.takeRetainedValue() as String? {
      return name
    }
    return AppLanguageStore.text("MIDI Source", "MIDI 输入")
  }

  private func sourceEndpoint(forUniqueID uid: Int32) -> MIDIEndpointRef? {
    let count = MIDIGetNumberOfSources()
    for index in 0..<count {
      let endpoint = MIDIGetSource(index)
      guard endpoint != 0 else { continue }
      if uniqueID(for: endpoint) == uid { return endpoint }
    }
    return nil
  }
}

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
    if selectedSourceID == nil {
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

  private func setupClient() {
    let createStatus = MIDIClientCreateWithBlock("xTCClient" as CFString, &client) { _ in }
    guard createStatus == noErr else {
      listeningState = AppLanguageStore.text("Unable to create MIDI client", "无法创建 MIDI Client") + ": \(createStatus)"
      return
    }

    let portStatus = MIDIInputPortCreateWithBlock(client, "xTCInput" as CFString, &inputPort) { [weak self] packetList, _ in
      self?.handle(packetList: packetList)
    }
    guard portStatus == noErr else {
      listeningState = AppLanguageStore.text("Unable to create MIDI input port", "无法创建 MIDI Input Port") + ": \(portStatus)"
      return
    }
  }

  private func handle(packetList: UnsafePointer<MIDIPacketList>) {
    let pointer = UnsafeMutablePointer(mutating: packetList)
    var packet = pointer.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
      let data = withUnsafeBytes(of: packet.data) { rawBuffer -> [UInt8] in
        Array(rawBuffer.prefix(Int(packet.length)))
      }
      process(bytes: data)
      packet = MIDIPacketNext(&packet).pointee
    }
  }

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
    guard quarterFrames.allSatisfy({ $0 != nil }) else { return }
    guard let f0 = quarterFrames[0], let f1 = quarterFrames[1], let f2 = quarterFrames[2], let f3 = quarterFrames[3], let f4 = quarterFrames[4], let f5 = quarterFrames[5], let f6 = quarterFrames[6], let f7 = quarterFrames[7] else {
      return
    }

    let frames = Int(f0) | (Int(f1 & 0x01) << 4)
    let seconds = Int(f2) | (Int(f3 & 0x03) << 4)
    let minutes = Int(f4) | (Int(f5 & 0x03) << 4)
    let hours = Int(f6) | (Int(f7 & 0x01) << 4)
    let rateCode = Int((f7 >> 1) & 0x03)

    guard let rate = TimecodeMath.inputRates.first(where: { $0.mtcRateCode == rateCode }) else { return }
    let tc = TimecodeValue(negative: false, hours: hours, minutes: minutes, seconds: seconds, frames: frames, delimiter: rate.dropFrame ? ";" : ":")

    Task { @MainActor in
      self.detectedRate = rate
      self.receivedTimecode = tc
      self.lastReceivedAt = Date()
      self.latencyEstimateMs = 0.5
      self.lastMessage = AppLanguageStore.text("Quarter Frame", "Quarter Frame")
      self.listeningState = AppLanguageStore.text("Received MTC", "收到 MTC") + " \(rate.label)"
    }
  }

  private func decodeFullFrame(_ bytes: [UInt8]) {
    guard bytes.count >= 10 else { return }
    let rateCode = Int((bytes[5] >> 5) & 0x03)
    let hours = Int(bytes[5] & 0x1f)
    let minutes = Int(bytes[6] & 0x3f)
    let seconds = Int(bytes[7] & 0x3f)
    let frames = Int(bytes[8] & 0x1f)

    guard let rate = TimecodeMath.inputRates.first(where: { $0.mtcRateCode == rateCode }) else { return }
    let tc = TimecodeValue(negative: false, hours: hours, minutes: minutes, seconds: seconds, frames: frames, delimiter: rate.dropFrame ? ";" : ":")

    Task { @MainActor in
      self.detectedRate = rate
      self.receivedTimecode = tc
      self.lastReceivedAt = Date()
      self.latencyEstimateMs = 0.2
      self.lastMessage = AppLanguageStore.text("Full Frame", "Full Frame")
      self.listeningState = AppLanguageStore.text("Received MTC", "收到 MTC") + " \(rate.label)"
    }
  }

  private func uniqueID(for endpoint: MIDIEndpointRef) -> Int32 {
    var uid: Int32 = 0
    MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
    return uid
  }

  private func displayName(for endpoint: MIDIEndpointRef) -> String {
    var cfName: Unmanaged<CFString>?
    if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cfName) == noErr, let name = cfName?.takeRetainedValue() as String? {
      return name
    }
    if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName) == noErr, let name = cfName?.takeRetainedValue() as String? {
      return name
    }
    return AppLanguageStore.text("MIDI Source", "MIDI 输入")
  }

  private func sourceEndpoint(forUniqueID uid: Int32) -> MIDIEndpointRef? {
    let count = MIDIGetNumberOfSources()
    for index in 0..<count {
      let endpoint = MIDIGetSource(index)
      guard endpoint != 0 else { continue }
      if uniqueID(for: endpoint) == uid {
        return endpoint
      }
    }
    return nil
  }
}

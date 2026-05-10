import Foundation
import CoreMIDI
import CoreAudio

struct MIDISourceItem: Identifiable, Hashable {
  let id: Int32
  let name: String
}

private struct MIDIPacketCapture {
  let bytes: [UInt8]
  let capturedAt: Date
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
  private var quarterFrameLocked = false
  private var lastQuarterPiece: Int?
  private var stableAnchorFrames: Int?
  private var stableAnchorAt: Date?
  private var stableRateID: String?
  private var unstableCandidateCount: Int = 0

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
    quarterFrames = Array(repeating: nil, count: 8)
    quarterFrameLocked = false
    lastQuarterPiece = nil
    stableAnchorFrames = nil
    stableAnchorAt = nil
    stableRateID = nil
    unstableCandidateCount = 0
    listeningState = AppLanguageStore.text("Disconnected", "未连接")
  }

  func clear() {
    quarterFrames = Array(repeating: nil, count: 8)
    quarterFrameLocked = false
    lastQuarterPiece = nil
    stableAnchorFrames = nil
    stableAnchorAt = nil
    stableRateID = nil
    unstableCandidateCount = 0
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
        for capture in extracted {
          self?.process(bytes: capture.bytes, capturedAt: capture.capturedAt)
        }
      }
    }
    guard portStatus == noErr else {
      listeningState = AppLanguageStore.text("Unable to create MIDI input port", "无法创建 MIDI Input Port") + ": \(portStatus)"
      return
    }
  }

  // MARK: - Packet extraction (called on CoreMIDI thread — must be static/nonisolated)

  private static func extractPackets(from packetList: UnsafePointer<MIDIPacketList>) -> [MIDIPacketCapture] {
    var result: [MIDIPacketCapture] = []
    let nowDate = Date()
    let nowHostTime = AudioGetCurrentHostTime()
    let pointer = UnsafeMutablePointer(mutating: packetList)
    var packet = pointer.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
      let bytes = withUnsafeBytes(of: packet.data) { rawBuffer in
        Array(rawBuffer.prefix(Int(packet.length)))
      }
      let capturedAt = captureDate(for: packet.timeStamp, nowDate: nowDate, nowHostTime: nowHostTime)
      result.append(MIDIPacketCapture(bytes: bytes, capturedAt: capturedAt))
      packet = MIDIPacketNext(&packet).pointee
    }
    return result
  }

  private static func captureDate(for hostTime: MIDITimeStamp, nowDate: Date, nowHostTime: UInt64) -> Date {
    // Zero timestamp means "now" in many CoreMIDI sources.
    if hostTime == 0 {
      return nowDate
    }

    if hostTime >= nowHostTime {
      let deltaNanos = AudioConvertHostTimeToNanos(hostTime - nowHostTime)
      return nowDate.addingTimeInterval(Double(deltaNanos) / 1_000_000_000.0)
    }

    let deltaNanos = AudioConvertHostTimeToNanos(nowHostTime - hostTime)
    return nowDate.addingTimeInterval(-Double(deltaNanos) / 1_000_000_000.0)
  }

  // MARK: - Packet processing (MainActor)

  private func process(bytes: [UInt8], capturedAt: Date) {
    guard let status = bytes.first else { return }

    switch status {
    case 0xF1 where bytes.count >= 2:
      let data = bytes[1]
      let piece = Int(data >> 4)
      guard piece < 8 else { return }
      quarterFrames[piece] = data & 0x0f
      if quarterFrames.allSatisfy({ $0 != nil }) {
        quarterFrameLocked = true
      }

      // Decode only on continuous QF sequence to avoid mixing stale/new nibbles,
      // which can cause visible timeline twitching.
      if quarterFrameLocked && shouldDecodeRollingQuarterFrame(for: piece) {
        decodeQuarterFrames(capturedAt: capturedAt)
      }
      lastQuarterPiece = piece

    case 0xF0:
      guard bytes.count >= 10,
            bytes[1] == 0x7f,
            bytes[2] == 0x7f,
            bytes[3] == 0x01,
            bytes[4] == 0x01,
            bytes.last == 0xf7
      else { return }
      decodeFullFrame(bytes, capturedAt: capturedAt)

    default:
      break
    }
  }

  private func decodeQuarterFrames(capturedAt: Date) {
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

    publishStableQuarterFrame(candidate: tc, rate: rate, capturedAt: capturedAt)
    latencyEstimateMs = 0.5
    lastMessage = AppLanguageStore.text("Quarter Frame", "Quarter Frame")
    listeningState = AppLanguageStore.text("Received MTC", "收到 MTC") + " \(rate.label)"
  }

  private func decodeFullFrame(_ bytes: [UInt8], capturedAt: Date) {
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
    lastReceivedAt = capturedAt
    latencyEstimateMs = 0.2
    lastMessage = AppLanguageStore.text("Full Frame", "Full Frame")
    listeningState = AppLanguageStore.text("Received MTC", "收到 MTC") + " \(rate.label)"

    // Full Frame is a locate/jump event — reset QF accumulator
    quarterFrames = Array(repeating: nil, count: 8)
    quarterFrameLocked = false
    lastQuarterPiece = nil
    stableAnchorFrames = TimecodeMath.timecodeToFrames(tc, rate: rate)
    stableAnchorAt = capturedAt
    stableRateID = rate.id
    unstableCandidateCount = 0
  }

  private func shouldDecodeRollingQuarterFrame(for piece: Int) -> Bool {
    guard let lastQuarterPiece else { return piece == 7 }
    if piece == lastQuarterPiece { return false }
    let expected = (lastQuarterPiece + 1) & 0x07
    return piece == expected
  }

  private func publishStableQuarterFrame(candidate: TimecodeValue, rate: FrameRateOption, capturedAt: Date) {
    let candidateFrames = TimecodeMath.timecodeToFrames(candidate, rate: rate)
    let dayFrames = max(1, Int((rate.fps * 86_400.0).rounded()))

    if stableRateID != rate.id || stableAnchorFrames == nil || stableAnchorAt == nil {
      stableRateID = rate.id
      stableAnchorFrames = candidateFrames
      stableAnchorAt = capturedAt
      unstableCandidateCount = 0
      detectedRate = rate
      receivedTimecode = candidate
      lastReceivedAt = capturedAt
      return
    }

    guard let anchorFrames = stableAnchorFrames, let anchorAt = stableAnchorAt else { return }
    let elapsed = max(0, capturedAt.timeIntervalSince(anchorAt))
    let predictedAdvance = Int((elapsed * rate.fps).rounded())
    let predictedFrames = normalizedFrameCount(anchorFrames + predictedAdvance, dayFrames: dayFrames)

    var delta = candidateFrames - predictedFrames
    if delta > dayFrames / 2 { delta -= dayFrames }
    if delta < -(dayFrames / 2) { delta += dayFrames }

    if abs(delta) <= 2 {
      stableAnchorFrames = candidateFrames
      stableAnchorAt = capturedAt
      unstableCandidateCount = 0
      detectedRate = rate
      receivedTimecode = candidate
      lastReceivedAt = capturedAt
      return
    }

    unstableCandidateCount += 1
    if unstableCandidateCount >= 8 {
      stableAnchorFrames = candidateFrames
      stableAnchorAt = capturedAt
      unstableCandidateCount = 0
      detectedRate = rate
      receivedTimecode = candidate
      lastReceivedAt = capturedAt
      return
    }

    let stabilizedTC = TimecodeMath.secondsToTimecode(Double(predictedFrames) / rate.fps, rate: rate)
    detectedRate = rate
    receivedTimecode = stabilizedTC
    lastReceivedAt = capturedAt
  }

  private func normalizedFrameCount(_ value: Int, dayFrames: Int) -> Int {
    let wrapped = value % dayFrames
    return wrapped >= 0 ? wrapped : wrapped + dayFrames
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

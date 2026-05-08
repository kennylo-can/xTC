import Foundation
import CoreMIDI

struct MIDIDestinationItem: Identifiable, Hashable {
  let id: Int32
  let name: String
}

@MainActor
final class MIDIOutputManager: ObservableObject {
  @Published var destinations: [MIDIDestinationItem] = []
  @Published var selectedDestinationID: Int32?
  @Published var statusText: String = AppLanguageStore.text("No output selected", "未选择输出")

  private var client = MIDIClientRef()
  private var outputPort = MIDIPortRef()

  init() {
    setupClient()
    refreshDestinations()
    if let first = destinations.first {
      selectedDestinationID = first.id
    }
  }

  func refreshDestinations() {
    var items: [MIDIDestinationItem] = []
    let count = MIDIGetNumberOfDestinations()
    for index in 0..<count {
      let endpoint = MIDIGetDestination(index)
      guard endpoint != 0 else { continue }
      let uid = uniqueID(for: endpoint)
      let name = displayName(for: endpoint)
      items.append(MIDIDestinationItem(id: uid, name: name))
    }
    destinations = items
    if selectedDestinationID == nil {
      selectedDestinationID = items.first?.id
    }
    statusText = items.isEmpty
      ? AppLanguageStore.text("No MIDI output available", "没有可用的 MIDI 输出")
      : AppLanguageStore.text("Listed", "已列出") + " \(items.count) " + AppLanguageStore.text("MIDI outputs", "个 MIDI 输出")
  }

  func send(fullFrame bytes: [UInt8]) {
    send(rawBytes: bytes)
  }

  func send(quarterFrames pieces: [[UInt8]]) {
    for piece in pieces {
      send(rawBytes: piece)
    }
  }

  func sendConvertedTimecode(fullFrame: [UInt8], quarterFrames: [[UInt8]]) {
    send(fullFrame: fullFrame)
    send(quarterFrames: quarterFrames)
    statusText = AppLanguageStore.text("Sent MTC", "已发送 MTC")
  }

  private func setupClient() {
    let createStatus = MIDIClientCreateWithBlock("xTCOutputClient" as CFString, &client) { _ in }
    guard createStatus == noErr else {
      statusText = AppLanguageStore.text("Unable to create MIDI client", "无法创建 MIDI Client") + ": \(createStatus)"
      return
    }

    let portStatus = MIDIOutputPortCreate(client, "xTCOutputPort" as CFString, &outputPort)
    guard portStatus == noErr else {
      statusText = AppLanguageStore.text("Unable to create MIDI output port", "无法创建 MIDI Output Port") + ": \(portStatus)"
      return
    }
  }

  private func send(rawBytes: [UInt8]) {
    guard let selectedDestinationID,
          let destination = destinationEndpoint(forUniqueID: selectedDestinationID)
    else {
      statusText = AppLanguageStore.text("No MIDI output selected", "未选择 MIDI 输出")
      return
    }

    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    let addResult: UnsafeMutablePointer<MIDIPacket>? = rawBytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return nil }
      return MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, buffer.count, baseAddress.assumingMemoryBound(to: UInt8.self))
    }
    guard addResult != nil else {
      statusText = AppLanguageStore.text("Failed to build MIDI packet", "写入 MIDI 包失败")
      return
    }

    let status = MIDISend(outputPort, destination, &packetList)
    if status != noErr {
      statusText = AppLanguageStore.text("Send failed", "发送失败") + ": \(status)"
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
    return AppLanguageStore.text("MIDI Destination", "MIDI 输出")
  }

  private func destinationEndpoint(forUniqueID uid: Int32) -> MIDIEndpointRef? {
    let count = MIDIGetNumberOfDestinations()
    for index in 0..<count {
      let endpoint = MIDIGetDestination(index)
      guard endpoint != 0 else { continue }
      if uniqueID(for: endpoint) == uid {
        return endpoint
      }
    }
    return nil
  }
}

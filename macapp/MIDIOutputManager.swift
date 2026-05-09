import Foundation
import CoreMIDI

struct MIDIDestinationItem: Identifiable, Hashable {
  let id: Int32
  let name: String
}

// MARK: - MTCClock
// Plain class (NOT @MainActor). All mutable state is confined to its private
// serial queue, which allows DispatchSourceTimer to call tick() at real-time
// priority without competing with the main actor.

private final class MTCClock {
  private let queue: DispatchQueue
  private var timer: DispatchSourceTimer?

  // All vars below are only ever touched on `queue`
  private var rate: FrameRateOption?
  private var piece: Int = 0
  private var baseSeconds: Double = 0
  private var baseDate: Date = Date()
  private var currentSeconds: Double = 0
  private var lastSentSeconds: Double?
  private var lastPositionUpdate: Date?          // nil = no update received yet
  private var isRunning: Bool = false
  private var destination: MIDIEndpointRef?
  var outputPort: MIDIPortRef = 0   // set once from setupClient; read on queue

  // Stop freewheeling after this many seconds with no updatePosition call.
  private let staleTimeout: TimeInterval = 0.6

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  // MARK: Public API (may be called from any thread/actor)

  func setOutputPort(_ port: MIDIPortRef) {
    queue.async { self.outputPort = port }
  }

  func setDestination(_ endpoint: MIDIEndpointRef?) {
    queue.async { self.destination = endpoint }
  }

  func start(rate: FrameRateOption) {
    queue.async { self.startInternal(rate: rate) }
  }

  func stop() {
    queue.async { self.stopInternal() }
  }

  func updateRate(_ newRate: FrameRateOption) {
    queue.async {
      let wasRunning = self.isRunning
      if wasRunning { self.stopInternal() }
      self.rate = newRate
      self.lastSentSeconds = nil    // force Full Frame on next updatePosition
      if wasRunning { self.startInternal(rate: newRate) }
    }
  }

  func updatePosition(tc: TimecodeValue, rate: FrameRateOption, capturedAt now: Date) {
    let newSeconds = TimecodeMath.timecodeToSeconds(tc, rate: rate)
    // Capture rate for use inside the closure (avoids @MainActor crossing)
    let fps = rate.fps

    queue.async {
      let isJump: Bool
      if let last = self.lastSentSeconds {
        let elapsed = now.timeIntervalSince(self.baseDate)
        let predicted = last + elapsed
        isJump = abs(newSeconds - predicted) > (2.0 / fps)
      } else {
        isJump = true
      }

      self.baseSeconds = newSeconds
      self.baseDate = now
      self.lastSentSeconds = newSeconds
      self.lastPositionUpdate = now

      if isJump {
        self.piece = 0
        self.currentSeconds = newSeconds
        self.sendFullFrame(tc: tc, rate: rate)
      }

      if !self.isRunning {
        self.startInternal(rate: rate)
      }
    }
  }

  // MARK: Private — all run on queue

  private func startInternal(rate: FrameRateOption) {
    self.rate = rate
    stopInternal()
    isRunning = true

    let interval = 1.0 / (rate.fps * 4.0)   // e.g. 120 Hz at 30 fps
    let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(200))
    t.setEventHandler { [weak self] in self?.tick() }
    t.resume()
    timer = t
  }

  private func stopInternal() {
    timer?.cancel()
    timer = nil
    isRunning = false
    lastPositionUpdate = nil
    lastSentSeconds = nil
  }

  private func tick() {
    guard isRunning, let rate = self.rate, lastSentSeconds != nil else { return }

    // If no updatePosition has arrived within the stale window, the input
    // signal is gone — stop the clock so we don't freerun indefinitely.
    if let last = lastPositionUpdate,
       Date().timeIntervalSince(last) > staleTimeout {
      stopInternal()
      lastPositionUpdate = nil
      return
    }

    // Snapshot TC once per 8-piece cycle so all nibbles encode the same frame.
    if piece == 0 {
      currentSeconds = baseSeconds + Date().timeIntervalSince(baseDate)
    }
    let tc = TimecodeMath.secondsToTimecode(currentSeconds, rate: rate)
    sendQF(piece: piece, tc: tc, rate: rate)
    piece = (piece + 1) % 8
  }

  private func sendQF(piece: Int, tc: TimecodeValue, rate: FrameRateOption) {
    let all = TimecodeMath.mtcQuarterFrameBytes(tc, rate: rate)
    guard piece < all.count else { return }
    sendRaw(all[piece])
  }

  private func sendFullFrame(tc: TimecodeValue, rate: FrameRateOption) {
    sendRaw(TimecodeMath.mtcFullFrameBytes(tc, rate: rate))
  }

  private func sendRaw(_ bytes: [UInt8]) {
    guard let dest = destination, outputPort != 0 else { return }
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    bytes.withUnsafeBytes { buf in
      guard let base = buf.baseAddress else { return }
      _ = MIDIPacketListAdd(
        &packetList, MemoryLayout<MIDIPacketList>.size,
        packet, 0, buf.count,
        base.assumingMemoryBound(to: UInt8.self)
      )
    }
    MIDISend(outputPort, dest, &packetList)
  }
}

// MARK: - MIDIOutputManager

@MainActor
final class MIDIOutputManager: ObservableObject {
  @Published var destinations: [MIDIDestinationItem] = []
  @Published var selectedDestinationID: Int32? {
    didSet { pushDestinationToClock() }
  }
  @Published var statusText: String = AppLanguageStore.text("No output selected", "未选择输出")

  private var client = MIDIClientRef()
  private var outputPort = MIDIPortRef()

  private let clockQueue = DispatchQueue(label: "xtc.mtc.outputclock", qos: .userInteractive)
  private lazy var clock = MTCClock(queue: clockQueue)

  init() {
    setupClient()
    refreshDestinations()
    if let first = destinations.first {
      selectedDestinationID = first.id
    }
  }

  // MARK: - Destination management

  func refreshDestinations() {
    var items: [MIDIDestinationItem] = []
    let count = MIDIGetNumberOfDestinations()
    for index in 0..<count {
      let endpoint = MIDIGetDestination(index)
      guard endpoint != 0 else { continue }
      items.append(MIDIDestinationItem(id: uniqueID(for: endpoint), name: displayName(for: endpoint)))
    }
    destinations = items

    if let current = selectedDestinationID, !items.contains(where: { $0.id == current }) {
      selectedDestinationID = items.first?.id
    } else if selectedDestinationID == nil {
      selectedDestinationID = items.first?.id
    }

    statusText = items.isEmpty
      ? AppLanguageStore.text("No MIDI output available", "没有可用的 MIDI 输出")
      : AppLanguageStore.text("Ready", "就绪") + " — \(items.count) " + AppLanguageStore.text("output(s)", "个输出")
    pushDestinationToClock()
  }

  // MARK: - Output Clock API

  func startClock(rate: FrameRateOption) {
    clock.start(rate: rate)
  }

  func stopClock() {
    clock.stop()
  }

  func updateRate(_ rate: FrameRateOption) {
    clock.updateRate(rate)
  }

  func updatePosition(tc: TimecodeValue, rate: FrameRateOption) {
    clock.updatePosition(tc: tc, rate: rate, capturedAt: Date())
  }

  // MARK: - Internals

  private func pushDestinationToClock() {
    let endpoint = selectedDestinationID.flatMap { destinationEndpoint(forUniqueID: $0) }
    clock.setDestination(endpoint)
  }

  private func setupClient() {
    let createStatus = MIDIClientCreateWithBlock("xTCOutputClient" as CFString, &client) { [weak self] notification in
      let msgID = notification.pointee.messageID
      if msgID == .msgObjectAdded || msgID == .msgObjectRemoved || msgID == .msgSetupChanged {
        Task { @MainActor [weak self] in
          self?.refreshDestinations()
        }
      }
    }
    guard createStatus == noErr else {
      statusText = AppLanguageStore.text("Unable to create MIDI client", "无法创建 MIDI Client") + ": \(createStatus)"
      return
    }

    let portStatus = MIDIOutputPortCreate(client, "xTCOutputPort" as CFString, &outputPort)
    guard portStatus == noErr else {
      statusText = AppLanguageStore.text("Unable to create MIDI output port", "无法创建 MIDI Output Port") + ": \(portStatus)"
      return
    }

    clock.setOutputPort(outputPort)
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
       let name = cfName?.takeRetainedValue() as String? { return name }
    if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName) == noErr,
       let name = cfName?.takeRetainedValue() as String? { return name }
    return AppLanguageStore.text("MIDI Destination", "MIDI 输出")
  }

  private func destinationEndpoint(forUniqueID uid: Int32) -> MIDIEndpointRef? {
    let count = MIDIGetNumberOfDestinations()
    for index in 0..<count {
      let endpoint = MIDIGetDestination(index)
      guard endpoint != 0 else { continue }
      if uniqueID(for: endpoint) == uid { return endpoint }
    }
    return nil
  }
}

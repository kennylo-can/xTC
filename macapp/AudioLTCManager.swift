import Foundation
import AVFAudio
import CoreAudio

struct AudioInputDeviceItem: Identifiable, Hashable {
  let id: AudioDeviceID
  let name: String
}

final class AudioLTCManager: ObservableObject {
  @Published var devices: [AudioInputDeviceItem] = []
  @Published var selectedDeviceID: AudioDeviceID?
  @Published var statusText: String = AppLanguageStore.text("Idle", "未监听")
  @Published var receivedTimecode: TimecodeValue?
  @Published var lastReceivedAt: Date?
  @Published var inputLevel: Double = 0
  @Published var latencyEstimateMs: Double?
  @Published var isLocked: Bool = false
  @Published var lockConfidence: Double = 0
  @Published var detectedRate: FrameRateOption?

  private let engine = AVAudioEngine()
  private let processingQueue = DispatchQueue(label: "xtc.audio.ltc")
  private let mainQueue = DispatchQueue.main
  private var sampleRate: Double = 48_000
  private var isRunning = false

  // Rate auto-detection state (processingQueue only)
  private var rateMaxFrame: Int = 0
  private var rateFrameCount: Int = 0
  private var currentBestRate: FrameRateOption?

  private var decoder: LTCDecoderRef?
  private var audioFrameOffset: Int64 = 0
  private var lastGoodDecodeAt: Date?
  private var lastDecodedFrames: Int?
  private var validFrameStreak: Int = 0

  // Hot-plug listener
  private var hotPlugListenerAdded = false
  private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

  init() {
    refreshDevices()
    if let defaultID = defaultInputDeviceID() ?? devices.first?.id {
      selectedDeviceID = defaultID
    }
    registerHotPlugListener()
  }

  deinit {
    shutdownAudio()
    releaseDecoder()
    removeHotPlugListener()
  }

  func refreshDevices() {
    let items = AudioLTCManager.enumerateInputDevices()
    devices = items
    if selectedDeviceID == nil {
      selectedDeviceID = defaultInputDeviceID() ?? items.first?.id
    }
    if items.isEmpty {
      statusText = AppLanguageStore.text("No audio input available", "没有可用的音频输入")
    }
  }

  func selectDevice(_ deviceID: AudioDeviceID) {
    selectedDeviceID = deviceID
    if isRunning {
      restartMonitoring()
    }
  }

  func startMonitoring() {
    guard selectedDeviceID != nil else {
      statusText = AppLanguageStore.text("No audio input available", "没有可用的音频输入")
      return
    }

    isRunning = true
    // Device is set per-engine via AUHAL in restartEngine() — doesn't touch system mic

    let detectedSampleRate = engine.inputNode.inputFormat(forBus: 0).sampleRate
    let currentSampleRate = detectedSampleRate > 0 ? detectedSampleRate : 48_000

    processingQueue.async { [weak self] in
      guard let self else { return }
      self.sampleRate = currentSampleRate
      self.rebuildDecoderLocked()
    }

    restartEngine()
  }

  func stopMonitoring() {
    isRunning = false
    shutdownAudio()
    processingQueue.async { [weak self] in
      self?.audioFrameOffset = 0
      if let decoder = self?.decoder {
        ltc_decoder_queue_flush(decoder)
      }
    }
    mainQueue.async {
      self.statusText = AppLanguageStore.text("Audio monitoring stopped", "音频监听已停止")
      self.inputLevel = 0
    }
  }

  func clear() {
    mainQueue.async {
      self.receivedTimecode = nil
      self.lastReceivedAt = nil
      self.latencyEstimateMs = nil
      self.isLocked = false
      self.lockConfidence = 0
    }

    processingQueue.async { [weak self] in
      guard let self else { return }
      self.lastGoodDecodeAt = nil
      self.lastDecodedFrames = nil
      self.validFrameStreak = 0
      self.audioFrameOffset = 0
      if let decoder = self.decoder {
        ltc_decoder_queue_flush(decoder)
      }
    }
  }

  private func restartMonitoring() {
    guard isRunning else { return }
    startMonitoring()
  }

  private func restartEngine() {
    shutdownAudio()

    // Set the input device only for this app's audio unit (AUHAL), without
    // touching the system-wide default microphone setting.
    if let deviceID = selectedDeviceID, let audioUnit = engine.inputNode.audioUnit {
      var device = deviceID
      let setStatus = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &device,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      )
      if setStatus != noErr {
        DispatchQueue.main.async {
          self.statusText = AppLanguageStore.text("Unable to switch input device", "无法切换输入设备") + ": \(setStatus)"
        }
        return
      }
    }

    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)

    inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      let frameCount = Int(buffer.frameLength)
      guard frameCount > 0 else { return }
      guard let channel = buffer.floatChannelData?[0] else { return }
      let copiedSamples = Array(UnsafeBufferPointer(start: channel, count: frameCount))

      self.processingQueue.async { [weak self] in
        self?.process(samples: copiedSamples)
      }
    }

    do {
      try engine.start()
      DispatchQueue.main.async {
        self.statusText = AppLanguageStore.text("Monitoring", "正在监听") + " \(self.deviceName(for: self.selectedDeviceID))"
      }
    } catch {
      DispatchQueue.main.async {
        self.statusText = AppLanguageStore.text("Audio start failed", "音频启动失败") + ": \(error.localizedDescription)"
      }
    }
  }

  private func process(samples: [Float]) {
    guard !samples.isEmpty else { return }

    let frameCount = samples.count
    var energy = 0.0

    guard let decoder else { return }

    samples.withUnsafeBufferPointer { buffer in
      if let base = buffer.baseAddress {
        ltc_decoder_write_float(decoder, UnsafeMutablePointer(mutating: base), samples.count, audioFrameOffset)
        audioFrameOffset += Int64(samples.count)
      }
    }

    var frame = LTCFrameExt()
    while ltc_decoder_read(decoder, &frame) > 0 {
      if let (timecode, rate) = decodeFrame(frame) {
        registerDecodedTimecode(timecode, rate: rate)
        let publishRate = currentBestRate
        mainQueue.async {
          self.receivedTimecode = timecode
          self.lastReceivedAt = Date()
          if let r = publishRate, r.id != self.detectedRate?.id {
            self.detectedRate = r
          }
        }
      }
    }

    for sample in samples {
      energy += Double(sample * sample)
    }

    let rms = frameCount > 0 ? sqrt(energy / Double(frameCount)) : 0
    let normalized = min(max(rms * 3.4, 0), 1)
    let estimatedLatencyMs = ((Double(frameCount) / sampleRate) * 1000.0) / 2.0
    mainQueue.async {
      self.inputLevel = (self.inputLevel * 0.72) + (normalized * 0.28)
      self.latencyEstimateMs = estimatedLatencyMs
    }

    ageOutLockIfNeeded()
  }

  /// Decode one LTC frame, auto-detecting frame rate from the Drop Frame bit and
  /// the observed frame count. Returns nil if the raw data is malformed.
  private func decodeFrame(_ frame: LTCFrameExt) -> (TimecodeValue, FrameRateOption)? {
    let raw = withUnsafeBytes(of: frame.ltc) { Array($0) }
    guard raw.count >= 10 else { return nil }

    func bcd(_ byte: UInt8, mask: UInt8) -> Int { Int(byte & mask) }

    let framesUnits  = bcd(raw[0], mask: 0x0f)
    let framesTens   = bcd(raw[1], mask: 0x03)
    let isDropFrame  = (raw[1] & 0x04) != 0      // SMPTE LTC bit 10 = Drop Frame flag
    let secondsUnits = bcd(raw[2], mask: 0x0f)
    let secondsTens  = bcd(raw[3], mask: 0x07)
    let minutesUnits = bcd(raw[4], mask: 0x0f)
    let minutesTens  = bcd(raw[5], mask: 0x07)
    let hoursUnits   = bcd(raw[6], mask: 0x0f)
    let hoursTens    = bcd(raw[7], mask: 0x03)

    let hours   = hoursTens   * 10 + hoursUnits
    let minutes = minutesTens * 10 + minutesUnits
    let seconds = secondsTens * 10 + secondsUnits
    let frames  = framesTens  * 10 + framesUnits

    guard hours < 24, minutes < 60, seconds < 60 else { return nil }

    // Auto-detect rate from DF bit and running max-frame observation.
    let rate = inferRate(frames: frames, isDropFrame: isDropFrame)
    guard let rate else { return nil }

    let delimiter: Character = isDropFrame ? ";" : ":"
    let tc = TimecodeValue(
      negative: false, hours: hours, minutes: minutes,
      seconds: seconds, frames: frames, delimiter: delimiter
    )
    guard case .success = TimecodeMath.validate(tc, rate: rate) else { return nil }
    return (tc, rate)
  }

  /// Updates the running frame-count statistics and returns the current best-guess
  /// rate once detection is confident, or nil while still accumulating evidence.
  private func inferRate(frames: Int, isDropFrame: Bool) -> FrameRateOption? {
    if isDropFrame {
      let rate = TimecodeMath.rate(id: "2997df", in: TimecodeMath.inputRates)
      currentBestRate = rate
      return rate
    }

    rateFrameCount += 1
    if frames > rateMaxFrame { rateMaxFrame = frames }

    // Definitive upper-bound detections (frame count proves a faster rate).
    if rateMaxFrame >= 25 {
      let rate = TimecodeMath.rate(id: "30", in: TimecodeMath.inputRates)
      currentBestRate = rate
      return rate
    }
    if rateMaxFrame >= 24 {
      let rate = TimecodeMath.rate(id: "25", in: TimecodeMath.inputRates)
      currentBestRate = rate
      return rate
    }
    // After ~30 frames without seeing frame ≥ 24, conclude 24 fps
    // (23.976 and 24 fps are indistinguishable from the data alone).
    if rateFrameCount >= 30 {
      let rate = TimecodeMath.rate(id: "24", in: TimecodeMath.inputRates)
      currentBestRate = rate
      return rate
    }
    return nil  // Still accumulating evidence
  }

  private func registerDecodedTimecode(_ timecode: TimecodeValue, rate: FrameRateOption) {
    let absoluteFrames = TimecodeMath.timecodeToFrames(timecode, rate: rate)
    let now = Date()
    let newConfidence: Double
    let goodDecode: Bool

    if let previous = lastDecodedFrames {
      let delta = absoluteFrames - previous
      if delta == 0 || delta == 1 {
        validFrameStreak = min(validFrameStreak + 1, 12)
        newConfidence = min(lockConfidence + 0.22, 1.0)
        goodDecode = true
      } else if abs(delta) <= 3 {
        validFrameStreak = min(validFrameStreak + 1, 12)
        newConfidence = min(lockConfidence + 0.12, 1.0)
        goodDecode = true
      } else if abs(delta) > 6 {
        validFrameStreak = 0
        newConfidence = max(lockConfidence - 0.28, 0.0)
        goodDecode = false
      } else {
        validFrameStreak = max(validFrameStreak - 1, 0)
        newConfidence = min(lockConfidence + 0.08, 1.0)
        goodDecode = true
      }
    } else {
      validFrameStreak = 1
      newConfidence = max(lockConfidence, 0.35)
      goodDecode = true
    }

    lastDecodedFrames = absoluteFrames
    lastGoodDecodeAt = now
    let locked = goodDecode && validFrameStreak >= 2 && newConfidence >= 0.6

    mainQueue.async {
      self.lockConfidence = newConfidence
      self.isLocked = locked
      self.statusText = locked
        ? AppLanguageStore.text("LTC locked", "LTC 已锁定") + " \(self.deviceName(for: self.selectedDeviceID))"
        : AppLanguageStore.text("Searching LTC", "正在搜索 LTC") + " \(self.deviceName(for: self.selectedDeviceID))"
    }
  }

  private func ageOutLockIfNeeded() {
    guard let lastGoodDecodeAt else { return }
    if Date().timeIntervalSince(lastGoodDecodeAt) > 0.55 {
      validFrameStreak = 0
      mainQueue.async {
        self.isLocked = false
        self.lockConfidence = max(self.lockConfidence * 0.6, 0.0)
        self.statusText = AppLanguageStore.text("Searching LTC", "正在搜索 LTC") + " \(self.deviceName(for: self.selectedDeviceID))"
      }
    }
  }

  private func rebuildDecoderLocked() {
    releaseDecoder()

    // Use 24 fps APV — the largest standard value — so the decoder buffer is
    // big enough for any frame rate (24 / 25 / 29.97 / 30 fps).
    let apv = max(1, Int((sampleRate / 24.0).rounded()))
    decoder = ltc_decoder_create(Int32(apv), 32)
    audioFrameOffset = 0
    lastGoodDecodeAt = nil
    lastDecodedFrames = nil
    validFrameStreak = 0
    rateMaxFrame = 0
    rateFrameCount = 0
    currentBestRate = nil
    if let decoder {
      ltc_decoder_queue_flush(decoder)
    }

    mainQueue.async {
      self.isLocked = false
      self.lockConfidence = 0
      self.detectedRate = nil
    }
  }

  private func releaseDecoder() {
    if let decoder {
      ltc_decoder_free(decoder)
    }
    decoder = nil
  }

  // MARK: - Hot-plug listener

  private func registerHotPlugListener() {
    guard !hotPlugListenerAdded else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.refreshDevices()
    }
    deviceListenerBlock = block
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      block
    )
    if status == noErr {
      hotPlugListenerAdded = true
    }
  }

  private func removeHotPlugListener() {
    guard hotPlugListenerAdded, let block = deviceListenerBlock else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      block
    )
    hotPlugListenerAdded = false
    deviceListenerBlock = nil
  }

  private func shutdownAudio() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine.reset()
  }

  private func deviceName(for deviceID: AudioDeviceID?) -> String {
    guard let deviceID else { return "Unknown Device" }
    return AudioLTCManager.deviceName(for: deviceID)
  }

  private static func enumerateInputDevices() -> [AudioInputDeviceItem] {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
      return []
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
      return []
    }

    return deviceIDs.compactMap { deviceID in
      guard hasInputStreams(deviceID) else { return nil }
      return AudioInputDeviceItem(id: deviceID, name: deviceName(for: deviceID))
    }
  }

  private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
      return false
    }
    return dataSize > 0
  }

  private static func deviceName(for deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var cfName: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &cfName) == noErr, let name = cfName?.takeUnretainedValue() else {
      return "Audio Device \(deviceID)"
    }
    return name as String
  }

  private func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize,
      &deviceID
    )
    return status == noErr ? deviceID : nil
  }
}

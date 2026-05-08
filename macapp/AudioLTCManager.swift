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

  private let engine = AVAudioEngine()
  private let processingQueue = DispatchQueue(label: "xtc.audio.ltc")
  private let mainQueue = DispatchQueue.main
  private var expectedRate: FrameRateOption = TimecodeMath.outputRates.first ?? FrameRateOption(id: "30", label: "30 fps", fps: 30, dropFrame: false, mtcRateCode: 3)
  private var sampleRate: Double = 48_000
  private var isRunning = false

  private var decoder: LTCDecoderRef?
  private var audioFrameOffset: Int64 = 0
  private var lastGoodDecodeAt: Date?
  private var lastDecodedFrames: Int?
  private var validFrameStreak: Int = 0

  init() {
    refreshDevices()
    if let defaultID = defaultInputDeviceID() ?? devices.first?.id {
      selectedDeviceID = defaultID
    }
  }

  deinit {
    shutdownAudio()
    releaseDecoder()
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

  func setExpectedRate(_ rate: FrameRateOption) {
    processingQueue.async { [weak self] in
      guard let self else { return }
      self.expectedRate = rate
      self.rebuildDecoderLocked()
    }
  }

  func selectDevice(_ deviceID: AudioDeviceID) {
    selectedDeviceID = deviceID
    if isRunning {
      restartMonitoring()
    }
  }

  func startMonitoring() {
    guard let deviceID = selectedDeviceID else {
      statusText = AppLanguageStore.text("No audio input available", "没有可用的音频输入")
      return
    }

    isRunning = true
    configureDefaultInputDevice(deviceID)

    let detectedSampleRate = engine.inputNode.inputFormat(forBus: 0).sampleRate
    let currentSampleRate = detectedSampleRate > 0 ? detectedSampleRate : 48_000
    let currentRate = expectedRate

    processingQueue.async { [weak self] in
      guard let self else { return }
      self.sampleRate = currentSampleRate
      self.expectedRate = currentRate
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
      if let timecode = decodeFrame(frame) {
        registerDecodedTimecode(timecode)
        mainQueue.async {
          self.receivedTimecode = timecode
          self.lastReceivedAt = Date()
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

  private func decodeFrame(_ frame: LTCFrameExt) -> TimecodeValue? {
    let raw = withUnsafeBytes(of: frame.ltc) { Array($0) }
    guard raw.count >= 10 else { return nil }

    func bcd(_ byte: UInt8, mask: UInt8) -> Int {
      Int(byte & mask)
    }

    let framesUnits = bcd(raw[0], mask: 0x0f)
    let framesTens = bcd(raw[1], mask: 0x03)
    let secondsUnits = bcd(raw[2], mask: 0x0f)
    let secondsTens = bcd(raw[3], mask: 0x07)
    let minutesUnits = bcd(raw[4], mask: 0x0f)
    let minutesTens = bcd(raw[5], mask: 0x07)
    let hoursUnits = bcd(raw[6], mask: 0x0f)
    let hoursTens = bcd(raw[7], mask: 0x03)

    let hours = hoursTens * 10 + hoursUnits
    let minutes = minutesTens * 10 + minutesUnits
    let seconds = secondsTens * 10 + secondsUnits
    let frames = framesTens * 10 + framesUnits

    guard hours < 24, minutes < 60, seconds < 60 else { return nil }

    let delimiter: Character = expectedRate.dropFrame ? ";" : ":"
    let tc = TimecodeValue(
      negative: false,
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      frames: frames,
      delimiter: delimiter
    )
    guard case .success = TimecodeMath.validate(tc, rate: expectedRate) else { return nil }
    return tc
  }

  private func registerDecodedTimecode(_ timecode: TimecodeValue) {
    let absoluteFrames = TimecodeMath.timecodeToFrames(timecode, rate: expectedRate)
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

    let apv = max(1, Int((sampleRate / expectedRate.fps).rounded()))
    decoder = ltc_decoder_create(Int32(apv), 8)
    audioFrameOffset = 0
    lastGoodDecodeAt = nil
    lastDecodedFrames = nil
    validFrameStreak = 0
    if let decoder {
      ltc_decoder_queue_flush(decoder)
    }

    mainQueue.async {
      self.isLocked = false
      self.lockConfidence = 0
    }
  }

  private func releaseDecoder() {
    if let decoder {
      ltc_decoder_free(decoder)
    }
    decoder = nil
  }

  private func configureDefaultInputDevice(_ deviceID: AudioDeviceID) {
    var device = deviceID
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      UInt32(MemoryLayout<AudioDeviceID>.size),
      &device
    )
    if status != noErr {
      mainQueue.async {
        self.statusText = AppLanguageStore.text("Unable to switch input device", "无法切换输入设备") + ": \(status)"
      }
    }
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

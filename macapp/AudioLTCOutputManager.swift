import Foundation
import AVFAudio
import CoreAudio
import os.lock

struct AudioOutputDeviceItem: Identifiable, Hashable {
  let id: AudioDeviceID
  let name: String
}

// MARK: - LTC Frame Encoder

/// Encodes one SMPTE LTC frame to BMC (Biphase Mark Code) audio samples.
/// Writes into a caller-supplied buffer to avoid heap allocation on the audio thread.
enum LTCFrameEncoder {

  /// Returns the exact number of samples one LTC frame occupies at the given sample rate and fps.
  /// LTC bit rate = fps × 80 bits/frame, so samplesPerBit = sampleRate / (fps × 80).
  static func samplesPerFrame(sampleRate: Double, fps: Double) -> Int {
    Int((sampleRate / fps).rounded())
  }

  /// Fills `out` with BMC-encoded samples for the given timecode frame.
  /// `level` carries waveform polarity across frames (must be ±amplitude).
  static func encode(
    tc: TimecodeValue,
    rate: FrameRateOption,
    sampleRate: Double,
    frameSampleCount: Int? = nil,
    amplitude: Float = 0.5,
    level: inout Float,
    into out: inout [Float]
  ) {
    let bits = buildBits(tc: tc, rate: rate)
    encodeBMC(bits: bits, sampleRate: sampleRate, fps: rate.fps,
              frameSampleCount: frameSampleCount,
              amplitude: amplitude, level: &level, into: &out)
  }

  // MARK: - Private helpers

  /// 80-bit LTC frame, layout per SMPTE ST 12-1 / matching libltc's bit positions.
  /// Each BCD digit is *not* contiguous; user-bit nibbles are interleaved.
  private static func buildBits(tc: TimecodeValue, rate: FrameRateOption) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 80)

    /// Write `n` low bits of `value` to b[start..<start+n], LSB first.
    func writeBits(_ value: Int, at start: Int, count n: Int) {
      for i in 0..<n { b[start + i] = UInt8((value >> i) & 1) }
    }

    // Time fields (positions match libltc's struct LTCFrame bit-fields)
    writeBits(tc.frames  % 10, at:  0, count: 4) // bits  0– 3: frame units
    // bits  4– 7: user bits 1
    writeBits(tc.frames  / 10, at:  8, count: 2) // bits  8– 9: frame tens (2 bits, max 3)
    b[10] = tc.delimiter == ";" ? 1 : 0          // bit 10: drop-frame flag
    // bit 11: colour-frame flag
    // bits 12–15: user bits 2
    writeBits(tc.seconds % 10, at: 16, count: 4) // bits 16–19: seconds units
    // bits 20–23: user bits 3
    writeBits(tc.seconds / 10, at: 24, count: 3) // bits 24–26: seconds tens (3 bits, max 5)
    // bit 27: biphase-mark phase-correction (filled in below)
    // bits 28–31: user bits 4
    writeBits(tc.minutes % 10, at: 32, count: 4) // bits 32–35: minutes units
    // bits 36–39: user bits 5
    writeBits(tc.minutes / 10, at: 40, count: 3) // bits 40–42: minutes tens (3 bits)
    // bit 43: binary-group flag 0
    // bits 44–47: user bits 6
    writeBits(tc.hours   % 10, at: 48, count: 4) // bits 48–51: hours units
    // bits 52–55: user bits 7
    writeBits(tc.hours   / 10, at: 56, count: 2) // bits 56–57: hours tens (2 bits, max 2)
    // bit 58: binary-group flag 2
    // bit 59: binary-group flag 1
    // bits 60–63: user bits 8

    // Sync word (bits 64–79). When shifted in MSB-first into a 16-bit register,
    // libltc looks for 0x3FFD = 0011_1111_1111_1101. So the on-wire order is:
    //   0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1
    let sync: [UInt8] = [0,0,1,1, 1,1,1,1, 1,1,1,1, 1,1,0,1]
    for i in 0..<16 { b[64 + i] = sync[i] }

    // Biphase-mark phase correction parity bit.
    // For 25fps this lives at bit 59; for 24/29.97/30 it is bit 27.
    // SMPTE rule: if zeros in bit positions 0..63 (excluding the parity bit itself)
    // are odd, set parity bit to 1. Since that set has 63 bits total, this is
    // equivalent to setting parity when ones(excluding parity) is even.
    let parityBitIndex = rate.id == "25" ? 59 : 27
    var onesExcludingParity = 0
    for i in 0..<64 where i != parityBitIndex {
      onesExcludingParity += Int(b[i])
    }
    b[parityBitIndex] = (onesExcludingParity % 2 == 0) ? 1 : 0

    return b
  }

  /// Biphase Mark Code encoding (Differential Manchester / FM).
  /// Bit rate = fps × 80, so samplesPerBit = sampleRate / (fps × 80).
  /// SMPTE BMC convention:
  ///   • Always a transition at cell *start* (the clock edge)
  ///   • Additional transition at cell *mid* only for '1' bits
  ///
  /// `level` is carried IN/OUT so the waveform stays continuous across frame
  /// boundaries — never inject a phantom transition between frames.
  private static func encodeBMC(
    bits: [UInt8],
    sampleRate: Double,
    fps: Double,
    frameSampleCount: Int?,
    amplitude: Float,
    level: inout Float,
    into out: inout [Float]
  ) {
    let totalSamples = max(1, frameSampleCount ?? Int((sampleRate / fps).rounded()))
    let spb: Double
    if let frameSampleCount {
      // Keep all 80 bits fully inside this frame's sample budget.
      // This avoids truncating the tail of a frame when non-integer fps
      // requires alternating frame sample counts.
      spb = Double(frameSampleCount) / 80.0
    } else {
      let bitRate = fps * 80.0
      spb = sampleRate / bitRate
    }

    out.removeAll(keepingCapacity: true)
    out.reserveCapacity(totalSamples)

    var cursor: Double = 0.0

    for bit in bits {
      let midPoint = cursor + spb * 0.5
      let cellEnd  = cursor + spb

      // Cell start: always a transition.
      level = -level
      while cursor < midPoint && out.count < totalSamples {
        out.append(level)
        cursor += 1
      }

      // Mid-cell: extra transition for '1' bits only.
      if bit != 0 { level = -level }
      while cursor < cellEnd && out.count < totalSamples {
        out.append(level)
        cursor += 1
      }
    }

    // Pad to exactly totalSamples if fractional spb left us short.
    while out.count < totalSamples { out.append(level) }
  }
}

// MARK: - Continuous LTC Clock

/// Runs on the audio render thread. Maintains a continuous, unbroken LTC output
/// stream by advancing the timecode one frame at a time.  A pending TC update
/// posted from the main thread is applied only at the next frame boundary.
/// Frame boundaries are determined by exact sample-clock position to avoid timing drift.
private final class LTCOutputClock {
  // All vars below are only ever touched on the audio render thread,
  // EXCEPT pendingXxx which are written under _pendingLock.

  private var currentTC: TimecodeValue?
  private var currentRate: FrameRateOption?
  private var frameBuffer = [Float]()          // pre-allocated, reused every frame
  private var encoderScratch = [Float](repeating: 0, count: 4096)
  private var ltcEncoder: OpaquePointer?
  private var encoderRateID: String?
  private var encoderSampleRate: Double = 0
  private var position: Int = 0
  private let encoderLevelDbfs: Double = -5.0  // conservative output level for stable decode without clipping
  private let encoderRiseTimeUs: Double = 40.0

  // Pending timecode from the main thread
  private var _pendingLock = os_unfair_lock()
  private var _pendingTC: TimecodeValue?
  private var _pendingRate: FrameRateOption?
  private var _pendingCapturedAt: Date?
  private var _hasPending: Bool = false
  var onMeasuredLatency: ((Double) -> Void)?
  private var pendingResyncCandidate: TimecodeValue?
  private var pendingResyncCount: Int = 0

  var sampleRate: Double = 48_000             // set once before first render

  deinit {
    if let ltcEncoder {
      xtc_ltc_encoder_free(ltcEncoder)
      self.ltcEncoder = nil
    }
  }

  // MARK: Called from main thread

  func post(tc: TimecodeValue, rate: FrameRateOption, capturedAt: Date) {
    os_unfair_lock_lock(&_pendingLock)
    _pendingTC   = tc
    _pendingRate = rate
    _pendingCapturedAt = capturedAt
    _hasPending  = true
    os_unfair_lock_unlock(&_pendingLock)
  }

  func reset() {
    os_unfair_lock_lock(&_pendingLock)
    _pendingTC  = nil
    _pendingRate = nil
    _pendingCapturedAt = nil
    _hasPending  = false
    os_unfair_lock_unlock(&_pendingLock)
    currentTC   = nil
    currentRate = nil
    position    = 0
    if let ltcEncoder {
      xtc_ltc_encoder_free(ltcEncoder)
      self.ltcEncoder = nil
    }
    encoderRateID = nil
    encoderSampleRate = 0
    pendingResyncCandidate = nil
    pendingResyncCount = 0
    frameBuffer.removeAll(keepingCapacity: true)
  }

  // MARK: Called from audio render thread

  /// Fill `dest` with the next `count` LTC samples.
  func render(into dest: UnsafeMutablePointer<Float>, count: Int) {
    var written = 0
    while written < count {
      if position >= frameBuffer.count {
        advanceToNextFrame()
        if frameBuffer.isEmpty { // still no TC — output silence
          dest.advanced(by: written).initialize(repeating: 0, count: count - written)
          return
        }
        position = 0
      }

      let available = frameBuffer.count - position
      let needed = count - written
      let chunk = min(available, needed)

      frameBuffer.withUnsafeBufferPointer { buf in
        (dest + written).initialize(from: buf.baseAddress! + position, count: chunk)
      }
      position += chunk
      written += chunk
    }
  }

  // MARK: Private

  private func advanceToNextFrame() {
    // Apply any pending TC update from the main thread.
    var newTC: TimecodeValue?
    var newRate: FrameRateOption?
    var pendingCapturedAt: Date?
    os_unfair_lock_lock(&_pendingLock)
    if _hasPending {
      newTC    = _pendingTC
      newRate  = _pendingRate
      pendingCapturedAt = _pendingCapturedAt
      _hasPending = false
    }
    os_unfair_lock_unlock(&_pendingLock)

    if let tc = newTC, let rate = newRate {
      if let current = currentTC, let currentRate {
        if currentRate.id == rate.id {
          let expected = nextTimecode(after: current, rate: rate)
          let deltaFrames = frameDelta(candidate: tc, reference: expected, rate: rate)
          if abs(deltaFrames) <= 2 {
            // Keep a stable clock when upstream jitter is within a tiny window.
            currentTC = expected
            pendingResyncCandidate = nil
            pendingResyncCount = 0
          } else {
            // Guard against one-off decode glitches. Require two consecutive
            // outlier anchors before resyncing, unless jump is very large.
            if abs(deltaFrames) >= Int(rate.fps * 2.0) {
              currentTC = tc
              pendingResyncCandidate = nil
              pendingResyncCount = 0
            } else if let candidate = pendingResyncCandidate,
                      frameDelta(candidate: tc, reference: candidate, rate: rate) == 1
                        || frameDelta(candidate: tc, reference: candidate, rate: rate) == 0 {
              pendingResyncCount += 1
              if pendingResyncCount >= 2 {
                currentTC = tc
                pendingResyncCandidate = nil
                pendingResyncCount = 0
              } else {
                currentTC = expected
              }
            } else {
              pendingResyncCandidate = tc
              pendingResyncCount = 1
              currentTC = expected
            }
          }
        } else {
          // Rate changed: resync immediately.
          currentTC = tc
          pendingResyncCandidate = nil
          pendingResyncCount = 0
        }
      } else {
        // First lock.
        currentTC = tc
        pendingResyncCandidate = nil
        pendingResyncCount = 0
      }
      currentRate = rate
      if let capturedAt = pendingCapturedAt {
        let milliseconds = max(0, Date().timeIntervalSince(capturedAt) * 1000.0)
        onMeasuredLatency?(milliseconds)
      }
    } else if let tc = currentTC, let rate = currentRate {
      // No new anchor this frame: free-run on the local stable clock.
      currentTC = nextTimecode(after: tc, rate: rate)
    } else {
      return  // no TC known yet
    }

    guard let tc = currentTC, let rate = currentRate else { return }
    ensureScratchCapacity()
    guard ensureEncoder(rate: rate) else {
      frameBuffer.removeAll(keepingCapacity: true)
      return
    }
    guard let ltcEncoder else {
      frameBuffer.removeAll(keepingCapacity: true)
      return
    }

    let len = encoderScratch.withUnsafeMutableBufferPointer { scratch in
      guard let base = scratch.baseAddress else { return Int32(0) }
      return xtc_ltc_encoder_encode_frame(
        ltcEncoder,
        Int32(tc.hours),
        Int32(tc.minutes),
        Int32(tc.seconds),
        Int32(tc.frames),
        tc.delimiter == ";" ? 1 : 0,
        base,
        Int32(scratch.count)
      )
    }

    if len <= 0 {
      frameBuffer.removeAll(keepingCapacity: true)
      return
    }
    frameBuffer.removeAll(keepingCapacity: true)
    frameBuffer.append(contentsOf: encoderScratch.prefix(Int(len)))
  }

  private func nextTimecode(after tc: TimecodeValue, rate: FrameRateOption) -> TimecodeValue {
    let totalFrames = TimecodeMath.timecodeToFrames(tc, rate: rate) + 1
    return TimecodeMath.secondsToTimecode(Double(totalFrames) / rate.fps, rate: rate)
  }

  private func frameDelta(candidate: TimecodeValue, reference: TimecodeValue, rate: FrameRateOption) -> Int {
    var deltaSeconds = TimecodeMath.timecodeToSeconds(candidate, rate: rate) - TimecodeMath.timecodeToSeconds(reference, rate: rate)
    if deltaSeconds > 43_200 { deltaSeconds -= 86_400 }
    if deltaSeconds < -43_200 { deltaSeconds += 86_400 }
    return Int((deltaSeconds * rate.fps).rounded())
  }

  private func ensureScratchCapacity() {
    let required = max(4096, Int(ceil(sampleRate / 23.0)) + 512)
    if encoderScratch.count < required {
      encoderScratch = [Float](repeating: 0, count: required)
    }
  }

  private func ensureEncoder(rate: FrameRateOption) -> Bool {
    let standard = tvStandard(for: rate)
    if let ltcEncoder {
      if encoderRateID != rate.id || abs(encoderSampleRate - sampleRate) > 0.5 {
        let rc = xtc_ltc_encoder_reinit(ltcEncoder, sampleRate, rate.fps, standard, encoderLevelDbfs, encoderRiseTimeUs)
        guard rc == 0 else { return false }
        encoderRateID = rate.id
        encoderSampleRate = sampleRate
      }
      return true
    }

    guard let created = xtc_ltc_encoder_create(sampleRate, rate.fps, standard, encoderLevelDbfs, encoderRiseTimeUs) else {
      return false
    }
    ltcEncoder = created
    encoderRateID = rate.id
    encoderSampleRate = sampleRate
    return true
  }

  private func tvStandard(for rate: FrameRateOption) -> Int32 {
    switch rate.id {
    case "25":
      return Int32(LTC_TV_625_50.rawValue)
    case "24", "2398":
      return Int32(LTC_TV_FILM_24.rawValue)
    default:
      return Int32(LTC_TV_525_60.rawValue)
    }
  }
}

// MARK: - AudioLTCOutputManager

@MainActor
final class AudioLTCOutputManager: ObservableObject {
  @Published var statusText: String = AppLanguageStore.text("Ready", "就绪")
  @Published var devices: [AudioOutputDeviceItem] = []
  @Published var measuredLatencyMs: Double?
  @Published var selectedDeviceID: AudioDeviceID? {
    didSet { if isRunning { restartEngine() } }
  }

  private let clock = LTCOutputClock()
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var isRunning = false

  init() {
    clock.onMeasuredLatency = { [weak self] ms in
      DispatchQueue.main.async {
        guard let self else { return }
        if let previous = self.measuredLatencyMs {
          self.measuredLatencyMs = (previous * 0.7) + (ms * 0.3)
        } else {
          self.measuredLatencyMs = ms
        }
      }
    }
    refreshDevices()
  }

  // MARK: Public API

  func startOutput(rate: FrameRateOption) {
    isRunning = true
    startEngine()
  }

  func stopOutput() {
    isRunning = false
    clock.reset()
    stopEngine()
    measuredLatencyMs = nil
    statusText = AppLanguageStore.text("LTC audio output stopped", "LTC 音频输出已停止")
  }

  func updateTimecode(_ tc: TimecodeValue, rate: FrameRateOption, inputCapturedAt: Date) {
    guard isRunning else { return }
    clock.post(tc: tc, rate: rate, capturedAt: inputCapturedAt)
  }

  func refreshDevices() {
    let items = Self.enumerateOutputDevices()
    devices = items
    if let cur = selectedDeviceID, !items.contains(where: { $0.id == cur }) {
      selectedDeviceID = items.first?.id
    } else if selectedDeviceID == nil {
      selectedDeviceID = items.first?.id
    }
  }

  // MARK: Engine lifecycle

  private func startEngine() {
    stopEngine()
    guard let deviceID = selectedDeviceID else {
      statusText = AppLanguageStore.text("No output device selected", "未选择输出设备")
      return
    }
    buildEngine(deviceID: deviceID)
  }

  private func stopEngine() {
    engine?.stop()
    if let node = sourceNode { engine?.detach(node) }
    engine = nil
    sourceNode = nil
  }

  private func restartEngine() {
    stopEngine()
    startEngine()
  }

  private func buildEngine(deviceID: AudioDeviceID) {
    let eng = AVAudioEngine()

    // Point the AUHAL output unit at the selected device.
    guard let au = eng.outputNode.audioUnit else {
      statusText = AppLanguageStore.text("Cannot access audio unit", "无法访问音频单元")
      return
    }
    var dev = deviceID
    let err = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0,
                                   &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard err == noErr else {
      statusText = AppLanguageStore.text("Cannot set output device", "无法设置输出设备") + " (\(err))"
      return
    }

    // Detect the device's native sample rate.
    let nativeSR = eng.outputNode.outputFormat(forBus: 0).sampleRate
    let sr = nativeSR > 0 ? nativeSR : 48_000
    clock.sampleRate = sr

    guard let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sr, channels: 1, interleaved: false) else {
      statusText = AppLanguageStore.text("Cannot create audio format", "无法创建音频格式")
      return
    }

    // The clock reference is captured by value (it's a class, so safe).
    let clockRef = clock
    let src = AVAudioSourceNode(format: monoFmt) { _, _, frameCount, abl -> OSStatus in
      let ptr = UnsafeMutableAudioBufferListPointer(abl)
      guard let raw = ptr[0].mData else { return noErr }
      let out = raw.bindMemory(to: Float.self, capacity: Int(frameCount))
      clockRef.render(into: out, count: Int(frameCount))
      return noErr
    }

    eng.attach(src)
    eng.connect(src, to: eng.outputNode, format: monoFmt)

    do {
      try eng.start()
      engine = eng
      sourceNode = src
      let name = devices.first(where: { $0.id == deviceID })?.name ?? "device"
      statusText = AppLanguageStore.text("Outputting to", "正在输出至") + " \(name)"
    } catch {
      statusText = AppLanguageStore.text("Audio engine failed", "音频引擎启动失败")
                   + ": \(error.localizedDescription)"
    }
  }

  // MARK: CoreAudio device enumeration

  private static func enumerateOutputDevices() -> [AudioOutputDeviceItem] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &sz) == noErr else { return [] }
    let n = Int(sz) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      guard hasOutput(id) else { return nil }
      return AudioOutputDeviceItem(id: id, name: name(for: id))
    }
  }

  private static func hasOutput(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr && sz > 0
  }

  private static func name(for id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &ref) == noErr,
          let s = ref?.takeUnretainedValue() else { return "Device \(id)" }
    return s as String
  }
}

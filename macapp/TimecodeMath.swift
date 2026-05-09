import Foundation

struct FrameRateOption: Identifiable, Hashable {
  let id: String
  let label: String
  let fps: Double
  let dropFrame: Bool
  let mtcRateCode: Int?

  var displayName: String { label }

  var nominalFrameCount: Int {
    if dropFrame { return 30 }
    return Int(fps.rounded())
  }
}

struct TimecodeValue: Equatable {
  var negative: Bool
  var hours: Int
  var minutes: Int
  var seconds: Int
  var frames: Int
  var delimiter: Character
}

enum TimecodeMathError: LocalizedError, Equatable {
  case message(String)

  var errorDescription: String? {
    switch self {
    case let .message(text):
      return text
    }
  }
}

enum TimecodeMath {
  static let inputRates: [FrameRateOption] = [
    FrameRateOption(id: "2398", label: "23.976", fps: 24000.0 / 1001.0, dropFrame: false, mtcRateCode: 0),
    FrameRateOption(id: "24", label: "24 fps", fps: 24, dropFrame: false, mtcRateCode: 0),
    FrameRateOption(id: "25", label: "25 fps", fps: 25, dropFrame: false, mtcRateCode: 1),
    FrameRateOption(id: "2997df", label: "29.97 DF", fps: 30000.0 / 1001.0, dropFrame: true, mtcRateCode: 2),
    FrameRateOption(id: "30", label: "30 fps", fps: 30, dropFrame: false, mtcRateCode: 3),
  ]

  static let outputRates = inputRates

  static func rate(id: String, in options: [FrameRateOption]) -> FrameRateOption {
    options.first { $0.id == id } ?? options[0]
  }

  static func formatRate(_ rate: FrameRateOption?) -> String {
    rate?.label ?? "--"
  }

  static func parse(_ text: String) -> Result<TimecodeValue, TimecodeMathError> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"^(-)?(\d{2}):(\d{2}):(\d{2})([:;])(\d{2})$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return .failure(.message(AppLanguageStore.text("Unable to parse the timecode format.", "无法解析时间码格式。")))
    }

    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    guard let match = regex.firstMatch(in: trimmed, range: range) else {
      return .failure(.message(AppLanguageStore.text("Enter timecode in HH:MM:SS:FF format.", "请输入 HH:MM:SS:FF 格式的时间码。")))
    }

    func group(_ index: Int) -> String {
      guard let r = Range(match.range(at: index), in: trimmed) else { return "" }
      return String(trimmed[r])
    }

    let negative = group(1) == "-"
    guard let hours = Int(group(2)),
          let minutes = Int(group(3)),
          let seconds = Int(group(4)),
          let frames = Int(group(6)),
          let delimiter = group(5).first
    else {
      return .failure(.message(AppLanguageStore.text("Unable to parse the timecode digits.", "无法解析时间码数字。")))
    }

    if hours > 23 {
      return .failure(.message(AppLanguageStore.text("Hours must be between 00 and 23.", "小时必须在 00-23 之间。")))
    }
    if minutes > 59 || seconds > 59 {
      return .failure(.message(AppLanguageStore.text("Minutes and seconds must be between 00 and 59.", "分钟和秒必须在 00-59 之间。")))
    }

    return .success(TimecodeValue(negative: negative, hours: hours, minutes: minutes, seconds: seconds, frames: frames, delimiter: delimiter))
  }

  static func validate(_ tc: TimecodeValue, rate: FrameRateOption) -> Result<Void, TimecodeMathError> {
    if tc.negative {
      return .failure(.message(AppLanguageStore.text("This version only handles non-negative timecode.", "当前版本仅处理非负时间码。")))
    }

    if tc.frames >= rate.nominalFrameCount {
      let limit = String(format: "%02d", rate.nominalFrameCount - 1)
      return .failure(.message(AppLanguageStore.text("Frames must be between 00 and \(limit).", "帧数必须在 00-\(limit) 之间。")))
    }

    if rate.dropFrame {
      if tc.delimiter != ";" {
        return .failure(.message(AppLanguageStore.text("29.97 DF timecode must use a semicolon separator.", "29.97 DF 时间码应使用分号作为分隔符。")))
      }
      let isTenthMinute = tc.minutes % 10 == 0
      if !isTenthMinute, tc.seconds == 0, tc.frames < 2 {
        return .failure(.message(AppLanguageStore.text("29.97 DF cannot start a minute with frame 00 or 01 unless it is a 10-minute boundary.", "29.97 DF 在非 10 分钟整的分钟起点不能使用 00 或 01 帧。")))
      }
    } else if tc.delimiter == ";" {
      return .failure(.message(AppLanguageStore.text("The semicolon is only valid for 29.97 DF timecode.", "分号只适用于 29.97 DF 时间码。")))
    }

    return .success(())
  }

  static func nominalFrameCount(for rate: FrameRateOption) -> Int {
    rate.nominalFrameCount
  }

  static func timecodeToFrames(_ tc: TimecodeValue, rate: FrameRateOption) -> Int {
    let labelFps = nominalFrameCount(for: rate)
    let totalSeconds = (tc.hours * 3600) + (tc.minutes * 60) + tc.seconds

    if rate.dropFrame {
      let nominalFrames = totalSeconds * labelFps + tc.frames
      let dropFrames = 2 * (tc.hours * 60 + tc.minutes - ((tc.hours * 60 + tc.minutes) / 10))
      return nominalFrames - dropFrames
    }

    return totalSeconds * labelFps + tc.frames
  }

  static func timecodeToSeconds(_ tc: TimecodeValue, rate: FrameRateOption) -> Double {
    Double(timecodeToFrames(tc, rate: rate)) / rate.fps
  }

  static func secondsToTimecode(_ seconds: Double, rate: FrameRateOption) -> TimecodeValue {
    let clampedSeconds = max(0, seconds)

    if rate.dropFrame {
      let actualFrames = Int((clampedSeconds * rate.fps).rounded())
      let framesPer10Minutes = 17_982
      let framesPerMinute = 1_798
      let tenMinuteChunks = actualFrames / framesPer10Minutes
      let remainder = actualFrames % framesPer10Minutes
      let droppedFrames = (tenMinuteChunks * 18) + (max(0, remainder - 2) / framesPerMinute * 2)
      var labelFrames = actualFrames + droppedFrames

      let framesPerHour = 108_000
      let framesPerMinuteLabel = 1_800
      let framesPerSecondLabel = 30

      let hours = (labelFrames / framesPerHour) % 24
      labelFrames %= framesPerHour
      let minutes = labelFrames / framesPerMinuteLabel
      labelFrames %= framesPerMinuteLabel
      let secondsPart = labelFrames / framesPerSecondLabel
      let frames = labelFrames % framesPerSecondLabel

      // Ensure DF-illegal positions (non-10th minute, sec=0, frame 0 or 1) are pushed to frame 2
      let correctedFrames: Int
      if minutes % 10 != 0, secondsPart == 0, frames < 2 {
        correctedFrames = 2
      } else {
        correctedFrames = frames
      }
      return TimecodeValue(negative: false, hours: hours, minutes: minutes, seconds: secondsPart, frames: correctedFrames, delimiter: ";")
    }

    let labelFps = nominalFrameCount(for: rate)
    var labelFrames = Int((clampedSeconds * rate.fps).rounded())
    let framesPerHour = labelFps * 3600
    let framesPerMinute = labelFps * 60

    let hours = (labelFrames / framesPerHour) % 24
    labelFrames %= framesPerHour
    let minutes = labelFrames / framesPerMinute
    labelFrames %= framesPerMinute
    let secondsPart = labelFrames / labelFps
    let frames = labelFrames % labelFps

    return TimecodeValue(negative: false, hours: hours, minutes: minutes, seconds: secondsPart, frames: frames, delimiter: ":")
  }

  static func normalize(_ tc: TimecodeValue, rate: FrameRateOption) -> TimecodeValue {
    secondsToTimecode(timecodeToSeconds(tc, rate: rate), rate: rate)
  }

  static func format(_ tc: TimecodeValue?) -> String {
    guard let tc else { return "--:--:--:--" }
    let delimiter = tc.delimiter
    return String(format: "%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds) + String(delimiter) + String(format: "%02d", tc.frames)
  }

  static func formatFrames(_ count: Int?) -> String {
    guard let count else { return "--" }
    return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
  }

  static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  static func mtcFullFrameBytes(_ tc: TimecodeValue, rate: FrameRateOption) -> [UInt8] {
    let code = rate.mtcRateCode ?? 0
    let hourByte = UInt8(((code & 0x03) << 5) | (tc.hours & 0x1f))
    let minuteByte = UInt8(tc.minutes & 0x3f)
    let secondByte = UInt8(tc.seconds & 0x3f)
    let frameByte = UInt8(tc.frames & 0x1f)
    return [0xf0, 0x7f, 0x7f, 0x01, 0x01, hourByte, minuteByte, secondByte, frameByte, 0xf7]
  }

  static func mtcQuarterFrameBytes(_ tc: TimecodeValue, rate: FrameRateOption) -> [[UInt8]] {
    let code = rate.mtcRateCode ?? 0
    let hourHighBit = (tc.hours >> 4) & 0x01
    let pieces: [UInt8] = [
      0x00 | UInt8(tc.frames & 0x0f),
      0x10 | UInt8((tc.frames >> 4) & 0x01),
      0x20 | UInt8(tc.seconds & 0x0f),
      0x30 | UInt8((tc.seconds >> 4) & 0x03),
      0x40 | UInt8(tc.minutes & 0x0f),
      0x50 | UInt8((tc.minutes >> 4) & 0x03),
      0x60 | UInt8(tc.hours & 0x0f),
      0x70 | UInt8(((code & 0x03) << 1) | hourHighBit),
    ]

    return pieces.map { data in [0xf1, data] }
  }

  static func detectedRate(forDelimiter delimiter: Character, frames: Int) -> FrameRateOption {
    if delimiter == ";" {
      return rate(id: "2997df", in: inputRates)
    }
    if frames >= 25 {
      return rate(id: "30", in: inputRates)
    }
    if frames >= 24 {
      return rate(id: "25", in: inputRates)
    }
    return rate(id: "24", in: inputRates)
  }
}

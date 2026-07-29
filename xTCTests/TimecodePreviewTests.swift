import XCTest
@testable import xTC

@MainActor
final class TimecodePreviewTests: XCTestCase {
  func testConversionPreviewDoesNotRequireProEntitlement() {
    let source = TimecodeValue(
      negative: false,
      hours: 1,
      minutes: 2,
      seconds: 3,
      frames: 12,
      delimiter: ":"
    )
    let inputRate = TimecodeMath.rate(id: "25", in: TimecodeMath.outputRates)
    let outputRate = TimecodeMath.rate(id: "2997df", in: TimecodeMath.outputRates)

    let seconds = TimecodeMath.timecodeToSeconds(source, rate: inputRate)
    let preview = TimecodeMath.secondsToTimecode(seconds, rate: outputRate)

    XCTAssertEqual(TimecodeMath.format(preview), "01:02:03;15")
  }

  func testLockedLivePipelineRejectsMIDIAndLTCStarts() {
    var midiStarts = 0
    var ltcStarts = 0
    let pipeline = makePipeline(
      startMIDI: { _ in midiStarts += 1 },
      startLTC: { _ in ltcStarts += 1 }
    )
    let rate = TimecodeMath.rate(id: "25", in: TimecodeMath.outputRates)

    XCTAssertFalse(pipeline.start(mode: .mtc, rate: rate))
    XCTAssertFalse(pipeline.start(mode: .ltc, rate: rate))
    XCTAssertEqual(midiStarts, 0)
    XCTAssertEqual(ltcStarts, 0)
  }

  func testLockedLivePipelineRejectsPositionSubmission() {
    var midiSubmissions = 0
    var ltcSubmissions = 0
    let pipeline = makePipeline(
      submitMIDI: { _, _, _ in midiSubmissions += 1 },
      submitLTC: { _, _, _ in ltcSubmissions += 1 }
    )
    let rate = TimecodeMath.rate(id: "25", in: TimecodeMath.outputRates)
    let timecode = TimecodeValue(
      negative: false,
      hours: 1,
      minutes: 2,
      seconds: 3,
      frames: 12,
      delimiter: ":"
    )

    XCTAssertFalse(
      pipeline.submit(
        mode: .mtc,
        timecode: timecode,
        rate: rate,
        inputCapturedAt: Date(timeIntervalSince1970: 100)
      )
    )
    XCTAssertFalse(
      pipeline.submit(
        mode: .ltc,
        timecode: timecode,
        rate: rate,
        inputCapturedAt: Date(timeIntervalSince1970: 100)
      )
    )
    XCTAssertEqual(midiSubmissions, 0)
    XCTAssertEqual(ltcSubmissions, 0)
  }

  func testLosingLivePipelineEntitlementStopsBothOutputs() {
    var midiStops = 0
    var ltcStops = 0
    let pipeline = makePipeline(
      stopMIDI: { midiStops += 1 },
      stopLTC: { ltcStops += 1 }
    )
    pipeline.setUnlocked(true)

    pipeline.setUnlocked(false)

    XCTAssertEqual(midiStops, 1)
    XCTAssertEqual(ltcStops, 1)
  }

  private func makePipeline(
    startMIDI: @escaping (FrameRateOption) -> Void = { _ in },
    stopMIDI: @escaping () -> Void = {},
    submitMIDI: @escaping (TimecodeValue, FrameRateOption, Date) -> Void = { _, _, _ in },
    startLTC: @escaping (FrameRateOption) -> Void = { _ in },
    stopLTC: @escaping () -> Void = {},
    submitLTC: @escaping (TimecodeValue, FrameRateOption, Date) -> Void = { _, _, _ in }
  ) -> LiveOutputPipeline {
    LiveOutputPipeline(
      startMIDI: startMIDI,
      stopMIDI: stopMIDI,
      submitMIDI: submitMIDI,
      startLTC: startLTC,
      stopLTC: stopLTC,
      submitLTC: submitLTC
    )
  }
}

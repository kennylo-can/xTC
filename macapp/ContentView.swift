import SwiftUI
import AppKit

enum InputMode: String, CaseIterable, Identifiable {
  case ltc
  case mtc

  var id: String { rawValue }
}

private struct ConversionSnapshot {
  let inputTimecode: TimecodeValue
  let inputRate: FrameRateOption
  let outputTimecode: TimecodeValue
  let inputFrames: Int
  let outputFrames: Int
  let fullFrame: String
  let quarterFrames: [[UInt8]]
}

private struct LayoutMetrics {
  let scale: CGFloat
  let titleBarHeight: CGFloat
  let outerPadding: CGFloat
  let panelSpacing: CGFloat
  let panelPadding: CGFloat
  let panelRadius: CGFloat
  let borderWidth: CGFloat
  let glowRadius: CGFloat
  let titleFont: CGFloat
  let titleIconSize: CGFloat
  let panelTitleFont: CGFloat
  let panelSubtitleFont: CGFloat
  let fieldTitleFont: CGFloat
  let bodyFont: CGFloat
  let smallFont: CGFloat
  let buttonFont: CGFloat
  let buttonHeight: CGFloat
  let segmentedWidth: CGFloat
  let segmentedHeight: CGFloat
  let deviceButtonHeight: CGFloat
  let rateChipFont: CGFloat
  let rateChipHPad: CGFloat
  let rateChipVPad: CGFloat
  let timecodeFont: CGFloat
  let timecodeCaptionFont: CGFloat
  let timecodeMinHeight: CGFloat
  let footerFont: CGFloat
  let statusFont: CGFloat
  let meterHeight: CGFloat
  let meterSpacing: CGFloat
  let centerColumnWidth: CGFloat
  let stackTopSpacing: CGFloat
}

struct ContentView: View {
  @StateObject private var midi = MIDIManager()
  @StateObject private var midiOut = MIDIOutputManager()
  @StateObject private var audio = AudioLTCManager()

  @AppStorage(AppLanguageStore.storageKey) private var languageRaw = AppLanguage.english.rawValue
  @State private var inputMode: InputMode = .ltc
  @State private var inputRateID: String = "2997df"
  @State private var outputRateID: String = "2997df"
  @State private var isRunning: Bool = true

  private var language: AppLanguage {
    AppLanguage(rawValue: languageRaw) ?? .english
  }

  private func t(_ english: String, _ chinese: String) -> String {
    language == .simplifiedChinese ? chinese : english
  }
  private var inputRate: FrameRateOption {
    TimecodeMath.rate(id: inputRateID, in: TimecodeMath.inputRates)
  }

  private var outputRate: FrameRateOption {
    TimecodeMath.rate(id: outputRateID, in: TimecodeMath.outputRates)
  }

  private var sourceTimecode: TimecodeValue? {
    switch inputMode {
    case .ltc:
      return audio.receivedTimecode
    case .mtc:
      return midi.receivedTimecode
    }
  }

  private var sourceRate: FrameRateOption? {
    switch inputMode {
    case .ltc:
      return inputRate
    case .mtc:
      return midi.detectedRate
    }
  }

  private var conversion: ConversionSnapshot? {
    guard let tc = sourceTimecode, let rate = sourceRate else { return nil }
    guard case .success = TimecodeMath.validate(tc, rate: rate) else { return nil }

    let inputSeconds = TimecodeMath.timecodeToSeconds(tc, rate: rate)
    let output = TimecodeMath.secondsToTimecode(inputSeconds, rate: outputRate)
    let inputFrames = TimecodeMath.timecodeToFrames(tc, rate: rate)
    let outputFrames = TimecodeMath.timecodeToFrames(output, rate: outputRate)

    return ConversionSnapshot(
      inputTimecode: tc,
      inputRate: rate,
      outputTimecode: output,
      inputFrames: inputFrames,
      outputFrames: outputFrames,
      fullFrame: TimecodeMath.hex(TimecodeMath.mtcFullFrameBytes(output, rate: outputRate)),
      quarterFrames: TimecodeMath.mtcQuarterFrameBytes(output, rate: outputRate)
    )
  }

  private var inputStatusText: String {
    switch inputMode {
    case .ltc:
      return audio.statusText
    case .mtc:
      return midi.listeningState
    }
  }

  var body: some View {
    let canvasWidth: CGFloat = 800
    let canvasHeight: CGFloat = 458
    let metrics = metrics(for: canvasWidth)

    ZStack {
      background

      VStack(spacing: 0) {
        VStack(spacing: metrics.stackTopSpacing) {
          mainContent(metrics: metrics)
          footerBar(metrics: metrics)
        }
        .padding(metrics.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .preferredColorScheme(.dark)
    .frame(width: canvasWidth, height: canvasHeight)
    .background(WindowSizer(size: CGSize(width: canvasWidth, height: canvasHeight)))
    .onAppear {
      syncInputPipeline()
      updateOutputPipeline()
      transmitIfNeeded()
    }
    .onChange(of: inputMode) { _ in
      syncInputPipeline()
      transmitIfNeeded()
    }
    .onChange(of: inputRateID) { _ in
      audio.setExpectedRate(inputRate)
      transmitIfNeeded()
    }
    .onChange(of: outputRateID) { _ in
      transmitIfNeeded()
    }
    .onChange(of: isRunning) { _ in
      transmitIfNeeded()
    }
    .onReceive(audio.$receivedTimecode) { _ in
      transmitIfNeeded()
    }
    .onReceive(audio.$inputLevel) { _ in }
    .onReceive(midi.$receivedTimecode) { _ in
      transmitIfNeeded()
    }
    .onReceive(midi.$detectedRate) { _ in
      transmitIfNeeded()
    }
    .onReceive(midi.$selectedSourceID) { _ in
      if inputMode == .mtc {
        midi.connectSelectedSource()
      }
    }
    .onReceive(midiOut.$selectedDestinationID) { _ in
      transmitIfNeeded()
    }
  }

  private func metrics(for width: CGFloat) -> LayoutMetrics {
    let scale: CGFloat = max(0.48, min(0.58, width / 1600.0))

    return LayoutMetrics(
      scale: scale,
      titleBarHeight: max(34, 40 * scale),
      outerPadding: max(10, 14 * scale),
      panelSpacing: max(10, 12 * scale),
      panelPadding: max(10, 14 * scale),
      panelRadius: max(14, 16 * scale),
      borderWidth: max(2, 2.5 * scale),
      glowRadius: max(8, 16 * scale),
      titleFont: max(14, 18 * scale),
      titleIconSize: max(18, 22 * scale),
      panelTitleFont: max(20, 26 * scale),
      panelSubtitleFont: max(10, 13 * scale),
      fieldTitleFont: max(11, 15 * scale),
      bodyFont: max(11, 14 * scale),
      smallFont: max(9, 11 * scale),
      buttonFont: max(11, 14 * scale),
      buttonHeight: max(30, 36 * scale),
      segmentedWidth: max(128, 150 * scale),
      segmentedHeight: max(28, 32 * scale),
      deviceButtonHeight: max(28, 32 * scale),
      rateChipFont: max(10, 12 * scale),
      rateChipHPad: max(8, 10 * scale),
      rateChipVPad: max(4, 6 * scale),
      timecodeFont: max(24, 46 * scale),
      timecodeCaptionFont: max(10, 12 * scale),
      timecodeMinHeight: max(82, 112 * scale),
      footerFont: max(10, 12 * scale),
      statusFont: max(9, 10 * scale),
      meterHeight: max(8, 10 * scale),
      meterSpacing: max(2, 3 * scale),
      centerColumnWidth: max(144, 170 * scale),
      stackTopSpacing: max(10, 14 * scale)
    )
  }

  private var background: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.07, green: 0.07, blue: 0.08),
          Color(red: 0.11, green: 0.11, blue: 0.12),
          Color(red: 0.05, green: 0.05, blue: 0.06)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      RadialGradient(
        colors: [
          Color.white.opacity(0.11),
          Color.clear
        ],
        center: .top,
        startRadius: 18,
        endRadius: 720
      )
      .ignoresSafeArea()
    }
  }

  private func titleBar(metrics: LayoutMetrics) -> some View {
    HStack(spacing: 12) {
      Image(nsImage: AppIconSupport.image())
        .resizable()
        .frame(width: metrics.titleIconSize + 4, height: metrics.titleIconSize + 4)
        .cornerRadius(7)

      Text(t("xTC v1.2", "xTC v1.2"))
        .font(.system(size: metrics.titleFont, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))

      Spacer(minLength: 12)

      Text(language == .simplifiedChinese ? "简体中文" : "English")
        .font(.system(size: metrics.smallFont, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.22))
        .clipShape(Capsule(style: .continuous))
    }
    .padding(.horizontal, 16)
    .frame(height: metrics.titleBarHeight)
    .background(
      LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .overlay(Divider().background(Color.white.opacity(0.16)), alignment: .bottom)
  }

  private func mainContent(metrics: LayoutMetrics) -> some View {
    HStack(alignment: .top, spacing: metrics.panelSpacing) {
      inputPanel(metrics: metrics)
      outputPanel(metrics: metrics)
      centerColumn(metrics: metrics)
    }
  }

  private func inputPanel(metrics: LayoutMetrics) -> some View {
    panelFrame(
      border: Color(red: 0.27, green: 0.58, blue: 1.0),
      glow: Color(red: 0.27, green: 0.58, blue: 1.0).opacity(0.18),
      metrics: metrics
    ) {
      VStack(alignment: .leading, spacing: 14 * metrics.scale) {
        panelHeader(
          title: t("INPUT", "输入"),
          subtitle: t("SOURCE:", "来源："),
          metrics: metrics
        ) {
          segmentedModePicker(metrics: metrics)
        }

        VStack(alignment: .leading, spacing: 8) {
          panelFieldTitle(t("SOURCE DEVICE:", "输入设备："), metrics: metrics)
          sourceDeviceRow(metrics: metrics)
        }

        VStack(alignment: .leading, spacing: 8) {
          panelFieldTitle(t("INPUT TIMECODE", "输入时间码"), metrics: metrics)
          timecodeDisplay(
            text: inputTimecodeText,
            tint: Color(red: 0.29, green: 1.0, blue: 0.33),
            caption: t("(Hrs:Mins:Secs:Frs)", "(时:分:秒:帧)"),
            metrics: metrics
          )
        }

        signalSection(
          title: t("INPUT SIGNAL", "输入信号"),
          metrics: metrics,
          accent: Color(red: 0.27, green: 0.58, blue: 1.0)
        )

        panelFooter(
          label: t("INPUT FRAME RATE:", "输入帧率："),
          value: rateDisplay(inputRate),
          accent: Color(red: 0.29, green: 1.0, blue: 0.33),
          subtext: inputStatusText,
          dots: .blue,
          metrics: metrics
        )
      }
    }
  }

  private func outputPanel(metrics: LayoutMetrics) -> some View {
    panelFrame(
      border: Color(red: 1.0, green: 0.52, blue: 0.16),
      glow: Color(red: 1.0, green: 0.52, blue: 0.16).opacity(0.18),
      metrics: metrics
    ) {
      VStack(alignment: .leading, spacing: 14 * metrics.scale) {
        panelHeader(
          title: t("OUTPUT", "输出"),
          subtitle: t("OUTPUT:", "输出："),
          metrics: metrics
        ) {
          outputModeBadge(metrics: metrics)
        }

        VStack(alignment: .leading, spacing: 8) {
          panelFieldTitle(t("OUTPUT DEVICE:", "输出设备："), metrics: metrics)
          outputDeviceRow(metrics: metrics)
        }

        VStack(alignment: .leading, spacing: 8) {
          panelFieldTitle(t("OUTPUT FRAME RATE:", "输出帧率："), metrics: metrics)
          outputRateStrip(metrics: metrics)
        }

        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            panelFieldTitle(t("OUTPUT TIMECODE", "输出时间码"), metrics: metrics)
            Spacer(minLength: 8)
            Text(t("(active conversion)", "(正在转换)"))
              .font(.system(size: metrics.bodyFont, weight: .medium))
              .foregroundStyle(Color(red: 1.0, green: 0.67, blue: 0.25))
          }

          timecodeDisplay(
            text: outputTimecodeText,
            tint: Color(red: 1.0, green: 0.58, blue: 0.16),
            caption: nil,
            metrics: metrics
          )
        }

        panelFooter(
          label: t("OUTPUT FRAME RATE:", "输出帧率："),
          value: rateDisplay(outputRate),
          accent: Color(red: 1.0, green: 0.58, blue: 0.16),
          subtext: isRunning ? t("(active)", "(运行中)") : t("(paused)", "(已暂停)"),
          dots: .orange,
          metrics: metrics
        )
      }
    }
  }

  private func centerColumn(metrics: LayoutMetrics) -> some View {
    VStack(spacing: 10) {
      Spacer(minLength: 14)

      Text(isRunning ? t("( CONVERTING )", "( 转换中 )") : t("( PAUSED )", "( 已暂停 )"))
        .font(.system(size: max(18, metrics.panelSubtitleFont + 8), weight: .bold, design: .rounded))
        .foregroundStyle(isRunning ? Color(red: 1.0, green: 0.58, blue: 0.18) : .white.opacity(0.42))
        .shadow(color: Color(red: 1.0, green: 0.58, blue: 0.18).opacity(isRunning ? 0.65 : 0.0), radius: 12)
        .lineLimit(1)
        .minimumScaleFactor(0.72)

      Button {
        isRunning.toggle()
      } label: {
        Text(isRunning ? t("STOP", "停止") : t("START", "开始"))
          .font(.system(size: metrics.buttonFont, weight: .semibold, design: .rounded))
          .frame(maxWidth: .infinity)
          .frame(height: metrics.buttonHeight)
          .foregroundStyle(.white.opacity(0.92))
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [Color.white.opacity(0.24), Color.white.opacity(0.12)],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
          )
      }
      .buttonStyle(.plain)

      latencyStat(metrics: metrics)
      Spacer(minLength: 14)
    }
    .padding(.horizontal, 2)
    .frame(maxHeight: .infinity)
    .frame(width: metrics.centerColumnWidth)
  }

  private func segmentedModePicker(metrics: LayoutMetrics) -> some View {
    HStack(spacing: 0) {
      modeSegment(title: "LTC", active: inputMode == .ltc, color: Color(red: 0.27, green: 0.58, blue: 1.0), metrics: metrics) {
        inputMode = .ltc
      }
      modeSegment(title: "MTC", active: inputMode == .mtc, color: Color.white.opacity(0.16), metrics: metrics) {
        inputMode = .mtc
      }
    }
    .frame(width: metrics.segmentedWidth, height: metrics.segmentedHeight)
    .background(Color.black.opacity(0.42))
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
    )
  }

  private func outputModeBadge(metrics: LayoutMetrics) -> some View {
    HStack(spacing: 0) {
      modeSegment(title: "LTC", active: false, color: Color.white.opacity(0.13), metrics: metrics) {}
        .disabled(true)
      modeSegment(title: "MTC", active: true, color: Color(red: 1.0, green: 0.55, blue: 0.12), metrics: metrics) {}
        .disabled(true)
    }
    .frame(width: metrics.segmentedWidth, height: metrics.segmentedHeight)
    .background(Color.black.opacity(0.42))
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
    )
  }

  private func modeSegment(title: String, active: Bool, color: Color, metrics: LayoutMetrics, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: max(12, metrics.buttonFont - 1), weight: .semibold, design: .rounded))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(active ? .black : .white.opacity(0.9))
        .background(active ? color : Color.clear)
    }
    .buttonStyle(.plain)
  }

  private func sourceDeviceRow(metrics: LayoutMetrics) -> some View {
    HStack(spacing: 8) {
      deviceDropdown(metrics: metrics)
      refreshButton(metrics: metrics) {
        switch inputMode {
        case .ltc:
          audio.refreshDevices()
        case .mtc:
          midi.refreshSources()
        }
      }
    }
  }

  private func outputDeviceRow(metrics: LayoutMetrics) -> some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(midiOut.destinations) { dest in
          Button(dest.name) {
            midiOut.selectedDestinationID = dest.id
          }
        }
      } label: {
        dropdownLabel(
          text: midiOut.selectedDestinationID.flatMap { id in
            midiOut.destinations.first(where: { $0.id == id })?.name
          } ?? t("No MIDI Output", "没有 MIDI 输出"),
          metrics: metrics
        )
      }

      refreshButton(metrics: metrics) {
        midiOut.refreshDestinations()
      }
    }
  }

  private func deviceDropdown(metrics: LayoutMetrics) -> some View {
    switch inputMode {
    case .ltc:
      return AnyView(
        Menu {
          ForEach(audio.devices) { device in
            Button(device.name) {
              audio.selectDevice(device.id)
            }
          }
        } label: {
          dropdownLabel(
            text: audio.selectedDeviceID.flatMap { id in
              audio.devices.first(where: { $0.id == id })?.name
            } ?? t("No Audio Input", "没有音频输入"),
            metrics: metrics
          )
        }
      )

    case .mtc:
      return AnyView(
        Menu {
          ForEach(midi.sources) { source in
            Button(source.name) {
              midi.selectedSourceID = source.id
            }
          }
        } label: {
          dropdownLabel(
            text: midi.selectedSourceID.flatMap { id in
              midi.sources.first(where: { $0.id == id })?.name
            } ?? t("No MIDI Input", "没有 MIDI 输入"),
            metrics: metrics
          )
        }
      )
    }
  }

  private func dropdownLabel(text: String, metrics: LayoutMetrics) -> some View {
    HStack(spacing: 10) {
      Text(text)
        .font(.system(size: metrics.bodyFont, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)

      Spacer(minLength: 8)

      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: max(10, metrics.smallFont), weight: .semibold))
        .foregroundStyle(.white.opacity(0.45))

      Image(systemName: "chevron.down")
        .font(.system(size: max(10, metrics.smallFont), weight: .semibold))
        .foregroundStyle(.white.opacity(0.55))
    }
    .padding(.horizontal, 14)
    .frame(height: metrics.deviceButtonHeight)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color(white: 0.31), Color(white: 0.22)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .strokeBorder(Color.black.opacity(0.56), lineWidth: 1)
    )
  }

  private func refreshButton(metrics: LayoutMetrics, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "arrow.clockwise")
        .font(.system(size: max(11, metrics.smallFont), weight: .semibold))
        .frame(width: metrics.deviceButtonHeight, height: metrics.deviceButtonHeight)
        .foregroundStyle(.white.opacity(0.82))
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
              LinearGradient(
                colors: [Color(white: 0.31), Color(white: 0.22)],
                startPoint: .top,
                endPoint: .bottom
              )
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.black.opacity(0.56), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
  }

  private func outputRateStrip(metrics: LayoutMetrics) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(TimecodeMath.outputRates, id: \.id) { rate in
          Button {
            outputRateID = rate.id
          } label: {
            Text(rateDisplay(rate))
              .font(.system(size: metrics.rateChipFont, weight: .semibold, design: .rounded))
              .foregroundStyle(outputRate.id == rate.id ? .black : .white.opacity(0.9))
              .padding(.horizontal, metrics.rateChipHPad)
              .padding(.vertical, metrics.rateChipVPad)
              .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(outputRate.id == rate.id ? Color(red: 1.0, green: 0.58, blue: 0.16) : Color.white.opacity(0.06))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .strokeBorder(outputRate.id == rate.id ? Color(red: 1.0, green: 0.58, blue: 0.16) : Color.white.opacity(0.08), lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity)
  }

  private func timecodeDisplay(text: String, tint: Color, caption: String?, metrics: LayoutMetrics) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.black.opacity(0.96))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.black.opacity(0.9), lineWidth: 1)
        )

      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color.white.opacity(0.06),
              Color.clear,
              Color.black.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .blendMode(.screen)

      VStack(spacing: 6) {
        if let caption {
          Text(caption)
            .font(.system(size: metrics.timecodeCaptionFont, weight: .medium))
            .foregroundStyle(tint.opacity(0.7))
        }

        Text(text)
          .font(.system(size: metrics.timecodeFont, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .tracking(1.4)
          .foregroundStyle(tint)
          .shadow(color: tint.opacity(0.92), radius: 9, x: 0, y: 0)
          .shadow(color: tint.opacity(0.45), radius: 20, x: 0, y: 0)
          .minimumScaleFactor(0.45)
          .lineLimit(1)
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 12)
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: metrics.timecodeMinHeight)
  }

  private func signalSection(title: String, metrics: LayoutMetrics, accent: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      panelFieldTitle(title, metrics: metrics)

      switch inputMode {
      case .ltc:
        audioLevelMeter(level: audio.inputLevel, accent: accent, metrics: metrics)
      case .mtc:
        statusChip(text: midi.lastMessage, accent: accent, metrics: metrics)
      }
    }
  }

  private func audioLevelMeter(level: Double, accent: Color, metrics: LayoutMetrics) -> some View {
    HStack(spacing: metrics.meterSpacing) {
      ForEach(0..<18, id: \.self) { index in
        let threshold = Double(index + 1) / 18.0
        Capsule(style: .continuous)
          .fill(level >= threshold ? accent : Color.white.opacity(0.08))
          .frame(height: metrics.meterHeight)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.black.opacity(0.45))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
    )
  }

  private func statusChip(text: String, accent: Color, metrics: LayoutMetrics) -> some View {
    Text(text.isEmpty ? t("Waiting...", "等待中...") : text)
      .font(.system(size: metrics.bodyFont, weight: .medium))
      .foregroundStyle(.white.opacity(0.84))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(accent.opacity(0.12))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(accent.opacity(0.18), lineWidth: 1)
      )
  }

  private func latencyStat(metrics: LayoutMetrics) -> some View {
    HStack(spacing: 10) {
      Text(t("Latency", "延迟"))
        .font(.system(size: max(10, metrics.smallFont), weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(1)

      Spacer(minLength: 8)

      Text(latencyValueText)
        .font(.system(size: max(11, metrics.bodyFont), weight: .semibold, design: .monospaced))
        .foregroundStyle(Color(red: 0.29, green: 1.0, blue: 0.33))
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.black.opacity(0.34))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
    )
    .padding(.top, 6)
  }

  private func statRow(label: String, value: String, tint: Color, metrics: LayoutMetrics) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: max(10, metrics.smallFont), weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.68))

      Spacer(minLength: 8)

      Text(value)
        .font(.system(size: max(11, metrics.bodyFont), weight: .semibold, design: .monospaced))
        .foregroundStyle(tint)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.black.opacity(0.34))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
    )
  }

  private func panelFrame(border: Color, glow: Color, metrics: LayoutMetrics, @ViewBuilder content: () -> some View) -> some View {
    content()
      .padding(metrics.panelPadding)
      .background(
        RoundedRectangle(cornerRadius: metrics.panelRadius, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color(white: 0.19),
                Color(white: 0.13)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: metrics.panelRadius, style: .continuous)
          .strokeBorder(border, lineWidth: metrics.borderWidth)
      )
      .overlay(
        RoundedRectangle(cornerRadius: metrics.panelRadius, style: .continuous)
          .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
          .blendMode(.screen)
      )
      .shadow(color: glow, radius: metrics.glowRadius, x: 0, y: 0)
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func panelHeader<Content: View>(title: String, subtitle: String, metrics: LayoutMetrics, @ViewBuilder trailing: () -> Content) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Text(title)
        .font(.system(size: metrics.panelTitleFont, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.95))

      Spacer(minLength: 8)

      Text(subtitle)
        .font(.system(size: metrics.panelSubtitleFont, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.80))

      trailing()
    }
  }

  private func panelFieldTitle(_ title: String, metrics: LayoutMetrics) -> some View {
    Text(title)
      .font(.system(size: metrics.fieldTitleFont, weight: .semibold, design: .rounded))
      .foregroundStyle(.white.opacity(0.9))
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func panelFooter(label: String, value: String, accent: Color, subtext: String, dots: DotColor, metrics: LayoutMetrics) -> some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 4) {
        Text(label)
          .font(.system(size: metrics.bodyFont, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.88))

        HStack(spacing: 0) {
          Text(value)
            .font(.system(size: metrics.bodyFont + 1, weight: .bold, design: .rounded))
            .foregroundStyle(accent)

          if !subtext.isEmpty {
            Text(" \(subtext)")
              .font(.system(size: metrics.bodyFont + 1, weight: .regular, design: .rounded))
              .foregroundStyle(subtext.contains("active") || subtext.contains("运行中") ? Color(red: 0.45, green: 0.8, blue: 0.45) : .white.opacity(0.55))
          }
        }
      }

      Spacer(minLength: 12)

      statusDots(color: dots)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func statusDots(color: DotColor) -> some View {
    HStack(spacing: 8) {
      Circle().fill(color.primary).frame(width: 9, height: 9)
      Circle().fill(color.primary).frame(width: 9, height: 9)
      Circle().fill(color.secondary).frame(width: 9, height: 9)
      Circle().fill(color.secondary).frame(width: 9, height: 9)
    }
  }

  private func footerBar(metrics: LayoutMetrics) -> some View {
    HStack {
      Text(t("xTC", "xTC"))
        .font(.system(size: metrics.footerFont, weight: .medium))
        .foregroundStyle(.white.opacity(0.72))

      Spacer()

      Text("\(isRunning ? t("SYNC LOCKED", "同步锁定") : t("PAUSED", "已暂停")) | \(outputTimecodeText) | \(outputStatusText)")
        .font(.system(size: metrics.footerFont - 1, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(Color.black.opacity(0.28))
    .overlay(Divider().background(Color.white.opacity(0.08)), alignment: .top)
  }

  private func rateDisplay(_ rate: FrameRateOption?) -> String {
    guard let rate else { return "--" }
    return rate.label
  }

  private var outputStatusText: String {
    midiOut.statusText
  }

  private var latencyValueText: String {
    let milliseconds: Double?
    switch inputMode {
    case .ltc:
      milliseconds = audio.latencyEstimateMs
    case .mtc:
      milliseconds = midi.latencyEstimateMs
    }

    guard let milliseconds else { return "--" }
    let frames = milliseconds / 1000.0 * outputRate.fps
    return String(format: "%.1f ms · %.1f fr", milliseconds, frames)
  }

  private var inputTimecodeText: String {
    if let conversion {
      return TimecodeMath.format(conversion.inputTimecode)
    }
    return "--:--:--:--"
  }

  private var outputTimecodeText: String {
    guard let conversion else { return "--:--:--:--" }
    return TimecodeMath.format(conversion.outputTimecode)
  }

  private func syncInputPipeline() {
    switch inputMode {
    case .ltc:
      midi.disconnect()
      audio.setExpectedRate(inputRate)
      audio.startMonitoring()
    case .mtc:
      audio.stopMonitoring()
      midi.connectSelectedSource()
    }
  }

  private func updateOutputPipeline() {
    midiOut.refreshDestinations()
  }

  private func transmitIfNeeded() {
    guard isRunning, let conversion else { return }
    midiOut.sendConvertedTimecode(
      fullFrame: TimecodeMath.mtcFullFrameBytes(conversion.outputTimecode, rate: outputRate),
      quarterFrames: TimecodeMath.mtcQuarterFrameBytes(conversion.outputTimecode, rate: outputRate)
    )
  }
}

private struct DotColor {
  let primary: Color
  let secondary: Color

  static let blue = DotColor(primary: Color(red: 0.27, green: 0.58, blue: 1.0), secondary: Color.white.opacity(0.16))
  static let orange = DotColor(primary: Color(red: 1.0, green: 0.58, blue: 0.16), secondary: Color.white.opacity(0.16))
}

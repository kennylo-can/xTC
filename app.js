import {
  INPUT_RATE_OPTIONS,
  OUTPUT_RATE_OPTIONS,
  bytesToHex,
  formatFrameCount,
  formatRate,
  formatTimecode,
  getRateById,
  mtcFullFrameBytes,
  mtcQuarterFrameBytes,
  normalizeTimecode,
  parseTimecodeText,
  quarterFramesToHexLines,
  secondsToTimecode,
  timecodeToFrameCount,
  timecodeToSeconds,
  validateTimecode,
} from "./timecode.js";

const dom = {
  inputTimecode: document.getElementById("inputTimecode"),
  inputRateSelect: document.getElementById("inputRateSelect"),
  outputRateSelect: document.getElementById("outputRateSelect"),
  inputRateBadge: document.getElementById("inputRateBadge"),
  outputRateBadge: document.getElementById("outputRateBadge"),
  sourceFormatPill: document.getElementById("sourceFormatPill"),
  absoluteSecondsPill: document.getElementById("absoluteSecondsPill"),
  rateCodePill: document.getElementById("rateCodePill"),
  inputDisplay: document.getElementById("inputDisplay"),
  outputDisplay: document.getElementById("outputDisplay"),
  inputFrameCount: document.getElementById("inputFrameCount"),
  outputFrameCount: document.getElementById("outputFrameCount"),
  frameMark: document.getElementById("frameMark"),
  statusLabel: document.getElementById("statusLabel"),
  inputValidation: document.getElementById("inputValidation"),
  fullFrameBytes: document.getElementById("fullFrameBytes"),
  quarterFrames: document.getElementById("quarterFrames"),
  copyFullFrame: document.getElementById("copyFullFrame"),
  copyQuarterFrames: document.getElementById("copyQuarterFrames"),
};

function populateSelect(select, options, selectedId) {
  select.innerHTML = "";
  for (const option of options) {
    const el = document.createElement("option");
    el.value = option.id;
    el.textContent = option.display;
    if (option.id === selectedId) {
      el.selected = true;
    }
    select.appendChild(el);
  }
}

populateSelect(dom.inputRateSelect, INPUT_RATE_OPTIONS, "2997df");
populateSelect(dom.outputRateSelect, OUTPUT_RATE_OPTIONS, "2997df");

function detectRateFromText(tc, selectedRate) {
  if (!tc) return selectedRate;
  if (selectedRate.id !== "auto") {
    return selectedRate;
  }

  if (tc.delimiter === ";") {
    return getRateById("2997df", INPUT_RATE_OPTIONS);
  }

  if (tc.frames >= 25) {
    return getRateById("30", INPUT_RATE_OPTIONS);
  }

  if (tc.frames >= 24) {
    return getRateById("25", INPUT_RATE_OPTIONS);
  }

  return getRateById("24", INPUT_RATE_OPTIONS);
}

function rateToLabel(rate) {
  return rate?.display ?? "--";
}

async function copyText(text) {
  if (!navigator.clipboard?.writeText) {
    return;
  }
  await navigator.clipboard.writeText(text);
}

function setCallout(type, message) {
  dom.inputValidation.textContent = message;
  dom.inputValidation.classList.toggle("error", type === "error");
}

function renderQuarterFrames(pieces) {
  dom.quarterFrames.innerHTML = "";
  for (const item of quarterFramesToHexLines(pieces)) {
    const row = document.createElement("div");
    row.className = "qf";
    row.innerHTML = `<span>${item.label}</span><span>${item.value}</span>`;
    dom.quarterFrames.appendChild(row);
  }
}

function render() {
  const parsed = parseTimecodeText(dom.inputTimecode.value);
  const inputPreset = getRateById(dom.inputRateSelect.value, INPUT_RATE_OPTIONS);
  const outputRate = getRateById(dom.outputRateSelect.value, OUTPUT_RATE_OPTIONS);

  dom.inputRateBadge.textContent = rateToLabel(inputPreset);
  dom.outputRateBadge.textContent = rateToLabel(outputRate);

  if (!parsed.ok) {
    dom.sourceFormatPill.textContent = "--";
    dom.absoluteSecondsPill.textContent = "0.000 s";
    dom.rateCodePill.textContent = `Rate ${outputRate.mtcRateCode ?? "--"}`;
    dom.inputDisplay.textContent = "--:--:--:--";
    dom.outputDisplay.textContent = "--:--:--:--";
    dom.inputFrameCount.textContent = "--";
    dom.outputFrameCount.textContent = "--";
    dom.fullFrameBytes.textContent = "F0 7F 7F 01 01 -- -- -- -- F7";
    dom.quarterFrames.innerHTML = "";
    setCallout("error", parsed.error);
    dom.statusLabel.textContent = "输入无效";
    return;
  }

  const inputRate = detectRateFromText(parsed.value, inputPreset);
  const validation = validateTimecode(parsed.value, inputRate);

  dom.sourceFormatPill.textContent = inputRate.dropFrame ? "Drop Frame" : "Non-Drop";
  dom.frameMark.textContent = parsed.value.delimiter === ";" ? "； DF" : "： NDF";
  dom.rateCodePill.textContent = `Rate ${outputRate.mtcRateCode}`;

  if (!validation.ok) {
    dom.absoluteSecondsPill.textContent = "0.000 s";
    dom.inputDisplay.textContent = formatTimecode(parsed.value, inputRate);
    dom.outputDisplay.textContent = "--:--:--:--";
    dom.inputFrameCount.textContent = "--";
    dom.outputFrameCount.textContent = "--";
    dom.fullFrameBytes.textContent = "F0 7F 7F 01 01 -- -- -- -- F7";
    dom.quarterFrames.innerHTML = "";
    setCallout("error", validation.error);
    dom.statusLabel.textContent = "输入校验失败";
    return;
  }

  const normalizedInput = normalizeTimecode(parsed.value, inputRate);
  const seconds = timecodeToSeconds(normalizedInput, inputRate);
  const outputTimecode = secondsToTimecode(seconds, outputRate);
  const fullFrame = mtcFullFrameBytes(outputTimecode, outputRate);
  const quarterFrames = mtcQuarterFrameBytes(outputTimecode, outputRate);
  const inputFrames = timecodeToFrameCount(normalizedInput, inputRate);
  const outputFrames = timecodeToFrameCount(outputTimecode, outputRate);

  dom.inputDisplay.textContent = formatTimecode(normalizedInput, inputRate);
  dom.outputDisplay.textContent = formatTimecode(outputTimecode, outputRate);
  dom.absoluteSecondsPill.textContent = `${seconds.toFixed(3)} s`;
  dom.inputFrameCount.textContent = formatFrameCount(inputFrames);
  dom.outputFrameCount.textContent = formatFrameCount(outputFrames);
  dom.fullFrameBytes.textContent = bytesToHex(fullFrame);
  renderQuarterFrames(quarterFrames);

  const delimiterNote = parsed.value.delimiter === ";" ? "检测到分号，按 DF 解析。" : "使用冒号，按所选输入帧率解析。";
  setCallout(
    "info",
    `${delimiterNote} 输入 ${rateToLabel(inputRate)} -> 输出 ${rateToLabel(outputRate)}，保持同一绝对时间。`,
  );
  dom.statusLabel.textContent = "转换正常";
}

dom.inputTimecode.addEventListener("input", render);
dom.inputRateSelect.addEventListener("change", render);
dom.outputRateSelect.addEventListener("change", render);

for (const button of document.querySelectorAll(".chip-button")) {
  button.addEventListener("click", () => {
    const sample = button.getAttribute("data-sample");
    if (!sample) return;
    const [timecode, rateId] = sample.split("|");
    dom.inputTimecode.value = timecode;
    dom.inputRateSelect.value = rateId === "29.97df" ? "2997df" : rateId;
    render();
  });
}

dom.copyFullFrame.addEventListener("click", async () => {
  await copyText(dom.fullFrameBytes.textContent ?? "");
  dom.copyFullFrame.textContent = "已复制";
  window.setTimeout(() => {
    dom.copyFullFrame.textContent = "复制";
  }, 900);
});

dom.copyQuarterFrames.addEventListener("click", async () => {
  const hex = Array.from(dom.quarterFrames.querySelectorAll(".qf span:last-child"))
    .map((node) => node.textContent)
    .join("\n");
  await copyText(hex);
  dom.copyQuarterFrames.textContent = "已复制";
  window.setTimeout(() => {
    dom.copyQuarterFrames.textContent = "复制";
  }, 900);
});

render();

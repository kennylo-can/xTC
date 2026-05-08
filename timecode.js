export const INPUT_RATE_OPTIONS = [
  { id: "auto", label: "自动检测", display: "自动检测", fps: null, dropFrame: null, mtcRateCode: null },
  { id: "23976", label: "23.976 fps", display: "23.976 fps", fps: 24000 / 1001, dropFrame: false, mtcRateCode: null },
  { id: "24", label: "24 fps", display: "24 fps", fps: 24, dropFrame: false, mtcRateCode: 0 },
  { id: "25", label: "25 fps", display: "25 fps", fps: 25, dropFrame: false, mtcRateCode: 1 },
  { id: "2997df", label: "29.97 fps DF", display: "29.97 fps DF", fps: 30000 / 1001, dropFrame: true, mtcRateCode: 2 },
  { id: "2997nd", label: "29.97 fps ND", display: "29.97 fps ND", fps: 30000 / 1001, dropFrame: false, mtcRateCode: null },
  { id: "30", label: "30 fps", display: "30 fps", fps: 30, dropFrame: false, mtcRateCode: 3 },
];

export const OUTPUT_RATE_OPTIONS = [
  { id: "24", label: "24 fps", display: "24 fps", fps: 24, dropFrame: false, mtcRateCode: 0 },
  { id: "25", label: "25 fps", display: "25 fps", fps: 25, dropFrame: false, mtcRateCode: 1 },
  { id: "2997df", label: "29.97 fps DF", display: "29.97 fps DF", fps: 30000 / 1001, dropFrame: true, mtcRateCode: 2 },
  { id: "30", label: "30 fps", display: "30 fps", fps: 30, dropFrame: false, mtcRateCode: 3 },
];

function roundToFrameCount(seconds, rate) {
  return Math.max(0, Math.round(seconds * rate.fps));
}

function nominalLabelFps(rate) {
  return rate.dropFrame ? 30 : Math.round(rate.fps);
}

export function getRateById(id, options = INPUT_RATE_OPTIONS) {
  return options.find((option) => option.id === id) ?? options[0];
}

export function formatRate(rate) {
  if (!rate) return "--";
  return rate.display ?? rate.label ?? "--";
}

export function parseTimecodeText(text) {
  const source = String(text ?? "").trim();
  const match = source.match(/^(-)?(\d{2}):(\d{2}):(\d{2})([:;])(\d{2})$/);
  if (!match) {
    return { ok: false, error: "请输入 HH:MM:SS:FF 形式的时间码。", raw: source };
  }

  const negative = Boolean(match[1]);
  const hours = Number(match[2]);
  const minutes = Number(match[3]);
  const seconds = Number(match[4]);
  const delimiter = match[5];
  const frames = Number(match[6]);

  if (hours > 23) {
    return { ok: false, error: "小时必须在 00-23 之间。", raw: source };
  }
  if (minutes > 59 || seconds > 59) {
    return { ok: false, error: "分钟和秒必须在 00-59 之间。", raw: source };
  }

  return {
    ok: true,
    value: { negative, hours, minutes, seconds, frames, delimiter },
    raw: source,
  };
}

export function validateTimecode(tc, rate) {
  if (!tc) {
    return { ok: false, error: "没有可转换的时间码。" };
  }

  if (tc.negative) {
    return { ok: false, error: "当前版本只处理非负时间码。" };
  }

  const frameLimit = nominalLabelFps(rate);
  if (tc.frames >= frameLimit) {
    return {
      ok: false,
      error: `帧数必须在 00-${String(frameLimit - 1).padStart(2, "0")} 之间。`,
    };
  }

  if (rate.dropFrame) {
    if (tc.delimiter !== ";") {
      return {
        ok: false,
        error: "29.97 DF 时间码应使用分号作为帧分隔符。",
      };
    }
    const isTenthMinute = tc.minutes % 10 === 0;
    if (!isTenthMinute && tc.seconds === 0 && tc.frames < 2) {
      return {
        ok: false,
        error: "29.97 DF 在非 10 分钟整的分钟起点不能使用 00 或 01 帧。",
      };
    }
  } else if (tc.delimiter === ";") {
    return {
      ok: false,
      error: "分号只适用于 29.97 DF 时间码，请切换输入帧率。",
    };
  }

  return { ok: true };
}

export function timecodeToFrameCount(tc, rate) {
  const labelFps = nominalLabelFps(rate);
  const totalSeconds = (tc.hours * 3600) + (tc.minutes * 60) + tc.seconds;

  if (rate.dropFrame) {
    const nominalFrames = totalSeconds * labelFps + tc.frames;
    const dropFrames = 2 * (tc.hours * 60 + tc.minutes - Math.floor((tc.hours * 60 + tc.minutes) / 10));
    return nominalFrames - dropFrames;
  }

  return totalSeconds * labelFps + tc.frames;
}

export function timecodeToSeconds(tc, rate) {
  const frames = timecodeToFrameCount(tc, rate);
  return frames / rate.fps;
}

export function secondsToTimecode(seconds, rate) {
  const clampedSeconds = Math.max(0, seconds);

  if (rate.dropFrame) {
    const actualFrames = roundToFrameCount(clampedSeconds, rate);
    const framesPer10Minutes = 17982;
    const framesPerMinute = 1798;
    const tenMinuteChunks = Math.floor(actualFrames / framesPer10Minutes);
    const remainder = actualFrames % framesPer10Minutes;
    const droppedFrames = (tenMinuteChunks * 18) + (Math.floor(Math.max(0, remainder - 2) / framesPerMinute) * 2);
    let labelFrames = actualFrames + droppedFrames;

    const framesPerHour = 108000;
    const framesPerMinuteLabel = 1800;
    const framesPerSecondLabel = 30;

    const hours = Math.floor(labelFrames / framesPerHour) % 24;
    labelFrames %= framesPerHour;
    const minutes = Math.floor(labelFrames / framesPerMinuteLabel);
    labelFrames %= framesPerMinuteLabel;
    const secondsPart = Math.floor(labelFrames / framesPerSecondLabel);
    const frames = labelFrames % framesPerSecondLabel;

    return { negative: false, hours, minutes, seconds: secondsPart, frames, delimiter: ";" };
  }

  const labelFps = nominalLabelFps(rate);
  let labelFrames = roundToFrameCount(clampedSeconds, rate);
  const framesPerHour = labelFps * 3600;
  const framesPerMinute = labelFps * 60;

  const hours = Math.floor(labelFrames / framesPerHour) % 24;
  labelFrames %= framesPerHour;
  const minutes = Math.floor(labelFrames / framesPerMinute);
  labelFrames %= framesPerMinute;
  const secondsPart = Math.floor(labelFrames / labelFps);
  const frames = labelFrames % labelFps;

  return {
    negative: false,
    hours,
    minutes,
    seconds: secondsPart,
    frames,
    delimiter: ":",
  };
}

export function normalizeTimecode(tc, rate) {
  const seconds = timecodeToSeconds(tc, rate);
  return secondsToTimecode(seconds, rate);
}

export function formatTimecode(tc, rate, forceDelimiter = null) {
  if (!tc) return "--:--:--:--";
  const delimiter = forceDelimiter ?? (rate?.dropFrame ? ";" : tc.delimiter ?? ":");
  return [
    String(tc.hours).padStart(2, "0"),
    String(tc.minutes).padStart(2, "0"),
    String(tc.seconds).padStart(2, "0"),
  ].join(":") + delimiter + String(tc.frames).padStart(2, "0");
}

export function formatFrameCount(count) {
  if (count == null || Number.isNaN(count)) return "--";
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 3 }).format(count);
}

function mtcRateCode(rate) {
  if (typeof rate.mtcRateCode === "number") {
    return rate.mtcRateCode;
  }
  return 0;
}

export function mtcFullFrameBytes(tc, rate) {
  const code = mtcRateCode(rate);
  const hourByte = ((code & 0x03) << 5) | (tc.hours & 0x1f);
  const minuteByte = tc.minutes & 0x3f;
  const secondByte = tc.seconds & 0x3f;
  const frameByte = tc.frames & 0x1f;

  return [0xf0, 0x7f, 0x7f, 0x01, 0x01, hourByte, minuteByte, secondByte, frameByte, 0xf7];
}

export function mtcQuarterFrameBytes(tc, rate) {
  const code = mtcRateCode(rate);
  const hourHighBit = (tc.hours >> 4) & 0x01;
  const pieces = [
    0x00 | (tc.frames & 0x0f),
    0x10 | ((tc.frames >> 4) & 0x01),
    0x20 | (tc.seconds & 0x0f),
    0x30 | ((tc.seconds >> 4) & 0x03),
    0x40 | (tc.minutes & 0x0f),
    0x50 | ((tc.minutes >> 4) & 0x03),
    0x60 | (tc.hours & 0x0f),
    0x70 | (((code & 0x03) << 1) | hourHighBit),
  ];

  return pieces.map((data) => [0xf1, data]);
}

export function bytesToHex(bytes) {
  return bytes.map((byte) => byte.toString(16).toUpperCase().padStart(2, "0")).join(" ");
}

export function quarterFramesToHexLines(pieces) {
  return pieces.map(([status, data], index) => ({
    label: `QF${index}`,
    value: bytesToHex([status, data]),
  }));
}

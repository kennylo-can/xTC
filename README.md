# xTC

## English

xTC is a local LTC to MTC converter for macOS.

It was built by combining two ideas:
- the LTC/MTC conversion workflow from Lockstep
- the timecode display style from Timecode Display

Main features:
- audio LTC input from a selected input device
- MIDI MTC input monitoring
- MIDI output selection for converted MTC
- output frame rate selection
- live latency display
- bilingual UI: English and Simplified Chinese

The macOS app is the main product in this repository. A lightweight web prototype is also included in the root folder.

## 中文

xTC 是一个运行在 macOS 上的本地 LTC 转 MTC 工具。

它的设计思路结合了两部分：
- 来自 Lockstep 的 LTC/MTC 转换流程
- 来自 Timecode Display 的时间码显示风格

主要功能：
- 从指定音频输入设备接收 LTC
- 监听 MIDI MTC 输入
- 选择 MIDI 输出设备并发送转换后的 MTC
- 自定义输出帧率
- 实时显示延迟
- 中英双语界面

这个仓库里的主程序是 macOS App，根目录里也保留了一份轻量级网页原型。

## Build / 构建

### macOS app

Run:

```bash
./build-app.sh
```

The script builds:
- the app bundle at `build/xTC.app`
- the bundled app icon
- the small C-based LTC decoder used by the audio pipeline

### DMG package

Run:

```bash
./build-dmg.sh
```

This creates:
- `build/xTC.app`
- `build/xTC.dmg`

The DMG includes:
- the app bundle
- a `Gatekeeper Guide.md` file with bilingual install/open instructions

### Permission / 权限

On first launch, macOS may ask for microphone permission.

If LTC input does not work, check:
- `System Settings > Privacy & Security > Microphone`
- make sure `xTC` is allowed

首次启动时，macOS 可能会请求麦克风权限。

如果 LTC 输入没有工作，请检查：
- `系统设置 > 隐私与安全性 > 麦克风`
- 确认 `xTC` 已允许

## Project Layout / 项目结构

- `macapp/` - native SwiftUI macOS app
- `vendor/libltc/` - small LTC decoder implementation adapted from libltc-style logic
- `assets/` - app icon source image
- `index.html`, `styles.css`, `app.js`, `timecode.js` - web prototype
- `build-app.sh` - build script for the macOS app
- `tools/` - helper scripts

## Third-party note / 第三方说明

The LTC decoder is adapted from the libltc decoding model. If you publish or redistribute this repository, keep the relevant upstream license notice with the source code.

LTC 解码器参考了 libltc 的解码模型。如果你要公开发布或重新分发这个仓库，请保留对应的上游许可说明。

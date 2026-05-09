# xTC v0.6 - Stable LTC Audio Output

## What's New

### 🎵 Stable LTC Audio Output
- **Frame Rate Stability**: Fixed timing instability in LTC (Linear Timecode) audio output
- **Sample-Accurate Boundaries**: Frames now advance at exact sample-clock positions, eliminating cumulative timing drift
- **Professional Grade**: Output timing now matches reference implementations like QLab

### 🔧 Technical Improvements
- Replaced buffer-based frame advancement with sample-clock-based boundaries
- Fixed rounding errors that accumulated at non-integer frame rates (e.g., 29.97 fps)
- Improved BMC (Biphase Mark Code) encoding consistency

## Installation

### macOS Gatekeeper Notice ⚠️

The first time you run xTC, macOS may show a "Cannot open xTC because the developer cannot be verified" message. This is because the app is not notarized. To open it:

1. **Find the app**: Locate xTC in Finder
2. **Right-click or Control+click** the app icon
3. **Select "Open"** from the context menu
4. **Click "Open"** in the security dialog

Alternatively, you can allow it in System Preferences:
- Go to **System Settings → Privacy & Security**
- Look for xTC in the "Security" section
- Click **"Open Anyway"**

After the first launch, you can open xTC normally without these steps.

---

## 安装和使用

### macOS 门卫警告 ⚠️

首次运行 xTC 时，macOS 可能会显示"无法打开 xTC，因为无法验证开发者"的信息。这是因为应用未经公证（notarized）。要打开它：

1. **找到应用**：在 Finder 中找到 xTC
2. **右键或按住 Control 键点击**应用图标
3. **从菜单中选择"打开"**
4. **在安全对话框中点击"打开"**

或者，您可以在系统设置中允许它：
- 进入 **System Settings → Privacy & Security**（系统设置 → 隐私与安全）
- 在"Security"（安全）部分找到 xTC
- 点击 **"Open Anyway"**（仍要打开）

首次启动后，您可以像正常应用一样打开 xTC，无需再进行这些步骤。

---

## Download

Download `xTC-v0.6.dmg` and mount it to install the app.

**Requires**: macOS 13.0 or later

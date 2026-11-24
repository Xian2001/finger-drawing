# Finger Drawing

Turn your Mac trackpad into a pen. Tap the trackpad with a gesture — and the left mouse button stays "pressed" until you tap again, so you can draw on the trackpad without pressing it down.

**中文文档：[README.zh-CN.md](README.zh-CN.md)** · **Download：[latest release](https://github.com/Xian2001/finger-drawing/releases/latest)**

> A tiny menu-bar app for macOS. No window, no dock icon — just a pencil in the menu bar.

---

## Features

- **Draw without pressing the trackpad** — after activation, moving one finger draws a continuous stroke in any app that accepts mouse drawing (Notes, Preview markup, Sketch, Photoshop, screenshot annotation…).
- **Configurable activation gesture**:

  | Gesture | Fingers | Taps |
  | --- | --- | --- |
  | Single-finger double tap (default) | 1 | 2 |
  | Single-finger triple tap | 1 | 3 |
  | Two-finger tap | 2 | 1 |
  | Three-finger tap | 3 | 1 |
  | Four-finger tap | 4 | 1 |

- **Master switch** in the menu bar: when unchecked, the app does nothing at all — the gesture is ignored and no mouse events are touched.
- **Optional global keyboard shortcut** — pick any combo (⌘ / ⌥ / ⌃ / ⇧ + key) in the gesture submenu; it toggles drawing mode from any app, and it does not need the Accessibility permission to be registered. **The trackpad gesture and the keyboard shortcut are mutually exclusive:** registering a shortcut switches the trackpad gesture off, and choosing a gesture again clears the shortcut.
- **State is remembered** — the master switch, the chosen gesture and the keyboard shortcut survive relaunches.
- **No accidental strokes** — a gesture only counts when it is a real tap: short (< 0.3 s), almost no movement, with the required number of fingers landing together (< 0.15 s apart). Pressing, holding or swiping never triggers it.

### Keyboard shortcut

Open the `触发手势` submenu → `键盘快捷键：未设置（点此设置）`. A small window appears: press the combo you want (it must include at least one of ⌘ / ⌥ / ⌃), then click **保存** (or press Return). Esc closes it without changing anything, and `清除快捷键` removes the assignment.

The shortcut is registered through Carbon's `RegisterEventHotKey`, so it works while another app is focused, the key press is swallowed instead of leaking into the focused app, and it needs no Accessibility permission. If macOS or another app already owns the combo, the app tells you and keeps the previous one.

Only one trigger is live at a time. Once a shortcut is saved, the touchpad gesture stops responding (so you cannot trip it by accident); `清除快捷键` or clicking any gesture in the same submenu switches back to the trackpad and retires the shortcut. The menu title always shows which one is currently active: `触发方式：触控板手势（…）` or `触发方式：键盘快捷键 ⌃⌥P`.

## Menu bar

```
✓ 启用 Finger Drawing          ← master switch
    开启画笔模式 / 关闭画笔模式    ← manual toggle
    触发手势：单指双击（默认）      ← gesture submenu
        ├ 单指双击 / 单指三击 / 两指 / 三指 / 四指轻点
        ├ ─────────────
        ├ 键盘快捷键：⌃⌥P（点此修改）
        └ 清除快捷键
  ─────────────────────
  重新连接触控板
  使用说明
  辅助功能权限：已就绪 / 未授权（点此授权）
  打开日志
  ─────────────────────
  退出 Finger Drawing  ⌘Q
```

The menu items are written in Chinese (the app's primary audience); the pencil icon shows a short `开` while drawing mode is on, and turns grey when the master switch is off.

## Requirements

- macOS 12.0 or newer (developed and tested on macOS 26 / 27, Apple Silicon).
- The shipped build is **arm64**. On an Intel Mac, rebuild from source with `-target x86_64-apple-macos12.0`.
- **Accessibility permission** is required — it is what lets the app keep the left mouse button pressed for you.

## Installation

### Option A — use the prebuilt app

1. Unzip the release, drag `Finger Drawing.app` wherever you like (`/Applications` is recommended).
2. First launch: **right-click → Open** (the app is not notarized).
3. macOS asks for **Accessibility** permission:
   - open **System Settings → Privacy & Security → Accessibility** and enable **Finger Drawing** (use `+` if it is not listed);
   - permission is read when the process starts, so relaunch the app (or use the menu item **辅助功能权限 → 重新启动**) after granting.

### Option B — build from source

```bash
xcode-select --install                 # Swift toolchain, once
git clone https://github.com/Xian2001/finger-drawing.git
cd finger-drawing
bash build.sh                          # produces "Finger Drawing.app"
```

`build.sh` compiles `src/main.swift` with `swiftc`, copies the `.icns`, then signs the bundle with the first `Apple Development` identity in your keychain (falling back to ad-hoc signing).

## Troubleshooting

**The checkbox is on but the menu still says “未授权”.**
The stored permission entry does not match the binary's code requirement (typical for **ad-hoc signed** builds, and after every re-sign). Untick and re-tick the app in the Accessibility list, or:

```bash
tccutil reset Accessibility com.fingerdrawing.app
```

then relaunch and grant again. Signing with a real identity (Apple Development or self-signed) makes the grant survive rebuilds.

**The pencil is not visible in the menu bar.**
On macOS 26/27 a new status item sits right after the application menus; when the bar runs out of room it is folded into the `«` overflow area. Click `«` to reveal it, or hold ⌘ and drag it to a free spot — macOS remembers the position.

**Three/four-finger taps also fire a system gesture.**
Disable the conflicting one in **System Settings → Trackpad → More Gestures** (e.g. “Look up & data detectors”, Mission Control).

**Drawing stops after switching apps.**
Check that drawing mode is still on (the pencil shows `开`); click once so the target app is frontmost, then continue.

## How it works

- **Gesture input**: raw trackpad frames from the private `MultitouchSupport.framework` (`MTDeviceCreateList` / `MTRegisterContactFrameCallback`). Only state `3`/`4` (actually touching) counts; hover states are ignored. Touch struct layout used here: 96-byte stride, `state` at offset 20, normalized `x`/`y` at offsets 32/36.
- **Taps are grouped**: fingers landing within 150 ms form one gesture; a gesture is valid only if every finger lifted within 300 ms and moved less than 4.8 % of the pad width. Consecutive valid gestures within 550 ms count as multiple taps.
- **Holding the mouse**: a `CGEvent` tap on `.cgSessionEventTap` watches pointer movement; the first move after activation posts a synthetic `leftMouseDown`, later moves post `leftMouseDragged`, deactivation posts `leftMouseUp`. Synthetic events carry an `eventSourceUserData` marker so the app never re-processes its own events.
- All thresholds live in `Tune` at the top of `src/main.swift`.

## Known limitations

- Uses a **private framework** — Apple rejects such apps from the App Store. Intended for personal use and self-distribution.
- Not notarized; Gatekeeper needs a right-click → Open on first launch.
- Raw touch parsing is version dependent: a future macOS may change the struct layout or the private API.
- Gesture recognition is heuristic — no sensitivity slider (yet). Patch `Tune` if it feels too eager or too slow.


## Releases

- Latest build: **[v1.1.0 — FingerDrawing-1.1.0.zip](https://github.com/Xian2001/finger-drawing/releases/latest)** (Apple Silicon, macOS 12+).
- The repository holds the source; the prebuilt `.app` and its zip live in the release assets (they are `.gitignore`d on purpose).

To cut a new release:

```bash
# 1. bump CFBundleShortVersionString / CFBundleVersion in src/Info.plist
bash build.sh                                          # rebuild the .app
ditto -c -k --keepParent "Finger Drawing.app" "FingerDrawing-x.y.z.zip"
# 2. publish tag vx.y.z and attach the zip as a release asset
```

## License

MIT — see [LICENSE](LICENSE).

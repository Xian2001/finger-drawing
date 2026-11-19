import AppKit
import CoreGraphics

// MARK: - 常量

/// 用于标记我们自己合成的事件，避免被自己的事件监听重复处理
private let kEventMark: Int64 = 0x42505254  // "BPRT"

private enum Tune {
    /// 单次轻点的最长触摸时长，超过即视为“按住”而不是“轻点”
    static let tapMaxDuration: Double = 0.30
    /// 同一次手势里，多根手指落下的最大时间差（三指轻点要靠它归并成一次手势）
    static let groupJoinWindow: Double = 0.15
    /// 连续轻点之间的最大间隔
    static let tapGap: Double = 0.55
    /// 单次轻点允许的手指移动量（归一化坐标，约等于 4% 触控板宽度）
    static let tapMaxMove: Float = 0.048
    /// 两次轻点允许的位置偏移，避免把两次无关的轻点当成一组
    static let pairMaxDistance: Float = 0.12
    /// 触控板触摸结构体在内存中的步长（本机实测 96 字节）
    static let fingerStride = 96
    /// 两次切换之间的最小间隔，防抖
    static let toggleDebounce: Double = 0.10
}

// MARK: - 触发手势

/// 触发画笔模式的手势，手指数量 + 轻点次数可组合
enum GesturePreset: Int, CaseIterable {
    case singleDouble = 0   // 单指双击
    case singleTriple = 1   // 单指三击
    case twoFinger = 2      // 两指轻点
    case threeFinger = 3    // 三指轻点
    case fourFinger = 4     // 四指轻点

    var fingers: Int {
        switch self {
        case .singleDouble, .singleTriple: return 1
        case .twoFinger: return 2
        case .threeFinger: return 3
        case .fourFinger: return 4
        }
    }

    var taps: Int {
        switch self {
        case .singleDouble: return 2
        case .singleTriple: return 3
        default: return 1
        }
    }

    var title: String {
        switch self {
        case .singleDouble: return "单指双击（默认）"
        case .singleTriple: return "单指三击"
        case .twoFinger: return "两指轻点"
        case .threeFinger: return "三指轻点"
        case .fourFinger: return "四指轻点"
        }
    }
}


// MARK: - 日志

final class AppLog {
    static let shared = AppLog()
    private let url: URL
    private var handle: FileHandle?
    private let fmt: DateFormatter

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        url = dir.appendingPathComponent("Finger Drawing.log")
        fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    var fileURL: URL { url }

    func log(_ message: String) {
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
        NSLog("[Finger Drawing] %@", message)
    }
}

// MARK: - 触控板原始触摸（识别触发手势）

typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private let trackpadFrameCallback: MTCallback = { _, fingers, count, _, _ in
    TouchTapDetector.shared?.handleFrame(fingers, count: count)
    return 0
}

final class TouchTapDetector {
    static var shared: TouchTapDetector?

    /// 识别到「触发手势」时回调（已切回主线程）
    var onGesture: (() -> Void)?

    /// 当前手势配置，改动后重置状态机
    var preset: GesturePreset = .singleDouble {
        didSet { resetState() }
    }

    /// 总开关：关闭时完全不处理触摸帧
    var isEnabled = true {
        didSet { if !isEnabled { resetState() } }
    }

    private var mtHandle: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var stopFn: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void)?

    // MARK: 状态机（全部在触控板回调线程里串行访问）

    private struct Contact {
        let id: Int32
        let start: CFAbsoluteTime
        var pos: (Float, Float)
        var maxMove: Float
    }

    /// 一组几乎同时按下的手指，三指轻点要靠它归并成一次手势
    private struct TapGroup {
        var start: CFAbsoluteTime
        var fingers: Int
        var alive: Int
        var valid: Bool
        var sumX: Float
        var sumY: Float
        var center: (Float, Float) {
            return (sumX / Float(max(fingers, 1)), sumY / Float(max(fingers, 1)))
        }
    }

    private var contacts: [Int32: Contact] = [:]
    private var group: TapGroup?
    private var tapCount = 0
    private var firstTapTime: CFAbsoluteTime = -1
    private var lastTapCenter: (Float, Float) = (0, 0)

    func start() -> Bool {
        guard devices.isEmpty else { return true }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            AppLog.shared.log("无法加载触控板私有框架")
            return false
        }
        mtHandle = handle

        guard let symList = dlsym(handle, "MTDeviceCreateList"),
              let symReg = dlsym(handle, "MTRegisterContactFrameCallback"),
              let symStart = dlsym(handle, "MTDeviceStart") else {
            AppLog.shared.log("触控板接口符号缺失")
            return false
        }
        let createList = unsafeBitCast(symList, to: (@convention(c) () -> CFArray?).self)
        let register = unsafeBitCast(symReg, to: (@convention(c) (UnsafeMutableRawPointer, MTCallback?) -> Void).self)
        let startEach = unsafeBitCast(symStart, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        if let symStop = dlsym(handle, "MTDeviceStop") {
            stopFn = unsafeBitCast(symStop, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        }

        guard let list = createList() else { return false }
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, trackpadFrameCallback)
            startEach(device, 0)
            devices.append(device)
        }
        AppLog.shared.log("已连接触控板设备数：\(devices.count)，触发手势：\(preset.title)")
        return !devices.isEmpty
    }

    func stop() {
        guard let stopFn = stopFn else { return }
        for d in devices { stopFn(d, 0) }
        devices.removeAll()
    }

    private func resetState() {
        contacts.removeAll()
        group = nil
        tapCount = 0
        firstTapTime = -1
    }

    /// 解析一帧触摸数据：只认「真正接触表面」（state 3/4），悬停（state 1/2）不参与判定。
    /// 同一帧里可以有多根手指，按落下时间把它们归并成一组手势。
    func handleFrame(_ fingers: UnsafeMutableRawPointer?, count: Int32) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        var seen = Set<Int32>()

        if let base = fingers, count > 0 {
            for i in 0..<Int(count) {
                let f = base.advanced(by: i * Tune.fingerStride)
                let state = f.load(fromByteOffset: 20, as: Int32.self)
                let id = f.load(fromByteOffset: 16, as: Int32.self)
                let pos = (f.load(fromByteOffset: 32, as: Float.self),
                           f.load(fromByteOffset: 36, as: Float.self))

                guard state == 3 || state == 4 else { continue }
                seen.insert(id)

                if var c = contacts[id] {
                    // 已有这根手指：更新位移，位移过大说明是滑动/拖动而不是轻点
                    let d = hypotf(pos.0 - c.pos.0, pos.1 - c.pos.1)
                    if d > c.maxMove { c.maxMove = d }
                    c.pos = pos
                    contacts[id] = c
                    if c.maxMove > Tune.tapMaxMove { group?.valid = false }
                } else {
                    // 新落下的手指
                    contacts[id] = Contact(id: id, start: now, pos: pos, maxMove: 0)
                    joinGroup(at: now, pos: pos)
                }
            }
        }

        // 这一帧里消失的手指视为抬起
        let gone = contacts.filter { !seen.contains($0.key) }
        for (id, c) in gone {
            contacts.removeValue(forKey: id)
            finishContact(c, at: now)
        }
    }

    private func joinGroup(at now: CFAbsoluteTime, pos: (Float, Float)) {
        if var g = group {
            // 落下时间足够接近，且还没超过四指：算作同一组手势
            if now - g.start <= Tune.groupJoinWindow, g.fingers < 4 {
                g.fingers += 1
                g.alive += 1
                g.sumX += pos.0
                g.sumY += pos.1
                group = g
                return
            }
            // 上一组还没收尾就又来了新手指，先把它结算掉
            finalizeGroup(g, at: now)
        }
        group = TapGroup(start: now, fingers: 1, alive: 1, valid: true, sumX: pos.0, sumY: pos.1)
    }

    private func finishContact(_ c: Contact, at now: CFAbsoluteTime) {
        guard var g = group else { return }
        let duration = now - c.start
        if duration > Tune.tapMaxDuration || c.maxMove > Tune.tapMaxMove {
            g.valid = false
        }
        g.alive -= 1
        if g.alive <= 0 {
            finalizeGroup(g, at: now)
            group = nil
        } else {
            group = g
        }
    }

    private func finalizeGroup(_ g: TapGroup, at now: CFAbsoluteTime) {
        group = nil
        guard g.valid, g.fingers == preset.fingers else {
            tapCount = 0
            firstTapTime = -1
            return
        }
        registerTap(center: g.center, at: now)
    }

    private func registerTap(center: (Float, Float), at now: CFAbsoluteTime) {
        // 单次轻点就触发的手势（两指/三指/四指）
        if preset.taps == 1 {
            fire()
            return
        }

        if tapCount > 0, now - firstTapTime <= Tune.tapGap {
            let d = hypotf(center.0 - lastTapCenter.0, center.1 - lastTapCenter.1)
            guard d <= Tune.pairMaxDistance else {
                tapCount = 0
                firstTapTime = -1
                return
            }
            tapCount += 1
        } else {
            tapCount = 1
            firstTapTime = now
        }
        lastTapCenter = center

        if tapCount >= preset.taps {
            tapCount = 0
            firstTapTime = -1
            fire()
        }
    }

    private func fire() {
        DispatchQueue.main.async { [weak self] in self?.onGesture?() }
    }
}

// MARK: - 鼠标事件引擎（连触 / 画笔）

private let mouseEventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<MouseEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

final class MouseEngine {
    static var shared: MouseEngine?

    var onStateChange: ((Bool) -> Void)?
    var onArmedChange: ((Bool) -> Void)?

    /// 总开关：关闭时程序完全不介入鼠标（不监听、不合成事件）
    private(set) var isArmed = true
    private(set) var isDrawing = false
    private var stroking = false
    private var lastToggleTime: CFAbsoluteTime = -1
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: 监听

    func start() -> Bool {
        if port != nil { return true }
        var mask: CGEventMask = 0
        for t in [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved] {
            mask |= (1 << t.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let newPort = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: mask,
                                              callback: mouseEventTapCallback,
                                              userInfo: refcon) else {
            return false
        }
        port = newPort
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newPort, 0)
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newPort, enable: true)
        AppLog.shared.log("鼠标事件监听已启动")
        return true
    }

    var isListening: Bool { port != nil }

    // MARK: 事件处理

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = port { CGEvent.tapEnable(tap: port, enable: true) }
            AppLog.shared.log("事件监听被系统暂停，已自动恢复")
            return Unmanaged.passUnretained(event)
        }

        // 自己合成的事件：直接放行，不参与任何逻辑
        if event.getIntegerValueField(.eventSourceUserData) == kEventMark {
            return Unmanaged.passUnretained(event)
        }

        guard isArmed, isDrawing else { return Unmanaged.passUnretained(event) }

        switch type {
        case .leftMouseDown, .leftMouseUp:
            // 画线过程中屏蔽实体点击，避免打断当前笔迹
            return nil
        case .mouseMoved:
            continueStroke(at: event.location)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: 状态切换

    func toggle() {
        guard isArmed else { return }
        setDrawing(!isDrawing)
    }

    /// 总开关：停用时立刻收笔，并且不再响应任何触控板双击
    func setArmed(_ on: Bool) {
        guard on != isArmed else { return }
        if !on, isDrawing {
            endStroke()
            isDrawing = false
        }
        isArmed = on
        AppLog.shared.log(on ? "总开关：启用" : "总开关：停用")
        DispatchQueue.main.async { [weak self] in self?.onArmedChange?(on) }
    }

    func setDrawing(_ on: Bool) {
        guard isArmed else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastToggleTime < Tune.toggleDebounce { return }
        guard on != isDrawing else { return }
        lastToggleTime = now

        if !on { endStroke() }
        isDrawing = on
        AppLog.shared.log(on ? "画笔模式：开启" : "画笔模式：关闭")
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(on) }
    }

    // MARK: 笔迹

    private func continueStroke(at loc: CGPoint) {
        if !stroking {
            stroking = true
            post(.leftMouseDown, at: loc)
            AppLog.shared.log("起笔 \(Int(loc.x)),\(Int(loc.y))")
        }
        post(.leftMouseDragged, at: loc)
    }

    private func endStroke() {
        guard stroking else { return }
        stroking = false
        post(.leftMouseUp, at: currentLocation())
        AppLog.shared.log("收笔")
    }

    private func currentLocation() -> CGPoint {
        return CGEvent(source: nil)?.location ?? .zero
    }

    private func post(_ type: CGEventType, at loc: CGPoint) {
        guard let e = CGEvent(mouseEventSource: eventSource,
                              mouseType: type,
                              mouseCursorPosition: loc,
                              mouseButton: .left) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: kEventMark)
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cghidEventTap)
    }

    func shutdown() {
        if stroking { endStroke() }
        if let port = port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }
}

// MARK: - 屏幕提示

final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func flash(_ text: String) {
        hideWork?.cancel()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: 250, height: 58)
        let frame = NSRect(x: visible.midX - size.width / 2,
                           y: visible.maxY - size.height - 52,
                           width: size.width, height: size.height)

        if panel == nil {
            let p = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.animationBehavior = .none
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel = p
        }
        guard let p = panel else { return }

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.86).cgColor
        container.layer?.cornerRadius = 14

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        label.frame = NSRect(x: 16, y: (size.height - label.frame.height) / 2,
                             width: size.width - 32, height: label.frame.height)
        container.addSubview(label)

        p.contentView = container
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = MouseEngine()
    private let detector = TouchTapDetector()
    private var permissionTimer: Timer?
    private let armMenuItem = NSMenuItem()
    private let drawMenuItem = NSMenuItem()
    private let permissionMenuItem = NSMenuItem()
    private let gestureMenuItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.shared.log("———— 启动 ————")

        NSApp.setActivationPolicy(.accessory)

        TouchTapDetector.shared = detector
        MouseEngine.shared = engine

        // 恢复上次的总开关状态（默认开启）
        let savedArmed = UserDefaults.standard.object(forKey: "armed") as? Bool ?? true
        engine.setArmed(savedArmed)
        detector.isEnabled = engine.isArmed

        // 恢复上次选择的触发手势（默认单指双击）
        detector.preset = GesturePreset(rawValue: UserDefaults.standard.integer(forKey: "gesturePreset")) ?? .singleDouble
        detector.onGesture = { [weak self] in
            self?.engine.toggle()
        }
        engine.onStateChange = { [weak self] on in
            self?.refreshUI()
            HUD.shared.flash(on ? "画笔模式 · 已开启" : "画笔模式 · 已关闭")
            self?.playFeedback(on: on)
        }
        engine.onArmedChange = { [weak self] on in
            guard let self = self else { return }
            self.detector.isEnabled = on
            UserDefaults.standard.set(on, forKey: "armed")
            self.refreshUI()
            HUD.shared.flash(on ? "Finger Drawing · 已启用" : "Finger Drawing · 已停用")
            self.playFeedback(on: on)
        }

        buildStatusItem()

        let touchOK = detector.start()
        if !touchOK {
            AppLog.shared.log("触控板触摸监听启动失败")
        }
        startEngine()

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.engine.shutdown()
            self?.detector.stop()
        }
    }

    // MARK: 启动事件监听 + 权限

    private func startEngine() {
        AppLog.shared.log("startEngine 开始，AXIsProcessTrusted=\(AXIsProcessTrusted())")
        if engine.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            refreshUI()
            return
        }
        refreshUI()
        // 只在第一次启动时自动弹系统的权限提示，避免每次启动都打扰
        let promptedKey = "didPromptAccessibility"
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: promptedKey) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            requestAccessibility()
        }
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.engine.start() {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.refreshUI()
                    HUD.shared.flash("辅助功能权限已就绪")
                }
            }
        }
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限"
        alert.informativeText = "Finger Drawing 要替你按住鼠标来实现“连触”，需要「辅助功能」权限。\n\n请在弹出的系统窗口里勾选「Finger Drawing」，然后点「重新启动」。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "重新启动")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            requestAccessibility()
            openAccessibilitySettings()
        } else if response == .alertSecondButtonReturn {
            relaunch()
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: 菜单栏

    private func buildGestureMenu() -> NSMenu {
        let sub = NSMenu()
        for preset in GesturePreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectGesture(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            item.state = (preset == detector.preset) ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    @objc private func selectGesture(_ sender: NSMenuItem) {
        guard let preset = GesturePreset(rawValue: sender.tag) else { return }
        detector.preset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: "gesturePreset")
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
        AppLog.shared.log("触发手势改为：\(preset.title)")
        refreshUI()
        HUD.shared.flash("触发手势：\(preset.fingers) 指 \(preset.taps) 击")
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "Finger Drawing")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()

        // 总开关：勾选即在用，取消勾选则整个软件不发挥任何作用
        armMenuItem.title = "启用 Finger Drawing"
        armMenuItem.action = #selector(toggleArmed)
        armMenuItem.target = self
        menu.addItem(armMenuItem)

        drawMenuItem.action = #selector(toggleDrawing)
        drawMenuItem.target = self
        drawMenuItem.indentationLevel = 1
        menu.addItem(drawMenuItem)

        // 触发手势：手指数量 + 轻点次数可自由组合
        gestureMenuItem.indentationLevel = 1
        gestureMenuItem.submenu = buildGestureMenu()
        menu.addItem(gestureMenuItem)

        menu.addItem(.separator())

        let reconnect = NSMenuItem(title: "重新连接触控板", action: #selector(reconnectTrackpad), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(reconnect)

        let tip = NSMenuItem(title: "使用说明", action: #selector(showHelp), keyEquivalent: "")
        tip.target = self
        menu.addItem(tip)

        permissionMenuItem.action = #selector(handlePermission)
        permissionMenuItem.target = self
        menu.addItem(permissionMenuItem)

        let logItem = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Finger Drawing", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshUI()
        AppLog.shared.log("状态栏项已创建 visible=\(statusItem.isVisible) menuItems=\(menu.items.count)")
    }

    private func refreshUI() {
        guard statusItem != nil else { return }
        let armed = engine.isArmed
        let on = engine.isDrawing

        armMenuItem.state = armed ? .on : .off
        drawMenuItem.title = on ? "关闭画笔模式" : "开启画笔模式"
        drawMenuItem.isEnabled = armed
        gestureMenuItem.title = "触发手势：\(detector.preset.title)"

        statusItem.button?.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Finger Drawing")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.appearsDisabled = !armed
        if on {
            statusItem.button?.title = " 开"
        } else {
            statusItem.button?.title = ""
        }

        if engine.isListening {
            permissionMenuItem.title = "辅助功能权限：已就绪"
        } else {
            permissionMenuItem.title = "辅助功能权限：未授权（点此授权）"
        }
    }

    private func playFeedback(on: Bool) {
        let name = on ? "Tink" : "Pop"
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: 动作

    @objc private func toggleArmed() {
        engine.setArmed(!engine.isArmed)
    }

    @objc private func toggleDrawing() {
        engine.toggle()
    }

    @objc private func reconnectTrackpad() {
        detector.stop()
        let ok = detector.start()
        AppLog.shared.log("重新连接触控板：\(ok)")
        HUD.shared.flash(ok ? "触控板已重新连接" : "触控板连接失败，请看日志")
    }

    @objc private func handlePermission() {
        if engine.isListening {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "权限已就绪"
            alert.informativeText = "当前已经可以正常使用画笔模式。"
            alert.runModal()
        } else {
            requestAccessibility()
            openAccessibilitySettings()
            showPermissionAlert()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(AppLog.shared.fileURL)
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Finger Drawing · 使用说明"
        alert.informativeText = """
        0. 菜单栏铅笔图标点开，第一项「启用 Finger Drawing」是总开关：
           勾选 = 正常使用；取消勾选 = 软件完全不生效，手势也不会有任何反应。
           这个状态会被记住，下次启动保持上次的设置。

        1. 「触发手势」可以换成你习惯的方式：单指双击（默认）、单指三击、
           两指轻点、三指轻点、四指轻点。选中后会记住，下次启动沿用。

        2. 做出该手势 → 开启「画笔模式」，屏幕顶部会有提示。
        3. 开启后手指在触控板上滑动即可连续画线，不需要按住触控板；
           此时鼠标等价于一直按下，备忘录、预览标记、Sketch、PS 等都能画。
        4. 再做出一次同样的手势 → 关闭画笔模式。

        小提示：
        · 必须是「轻点」：手指落下再抬起，不移动；用力按下、按住、滑动都不算。
        · 三指/四指轻点可能与系统手势（如查询、调度中心）冲突，
          可在「系统设置 → 触控板」里关掉对应的系统手势。
        · 画线过程中单击不会打断笔迹。
        · 需要给本应用授予「辅助功能」权限，否则无法替你按住鼠标。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        engine.shutdown()
        detector.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

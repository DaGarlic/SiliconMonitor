import AppKit
import ApplicationServices

// The tap callback is a C function pointer, so it can't capture state; the tap lives in a global.
nonisolated(unsafe) private var activeTap: CFMachPort?

private let swallowEvents: CGEventTapCallBack = { _, type, event, _ in
    // macOS disables a tap that stalls; turn it back on instead of letting keys leak through.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = activeTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return nil // drop key, modifier and media-key events
}

/// Keyboard lock and screen blackout for wiping the machine down.
@MainActor
final class CleaningMode: ObservableObject {
    static let keyboardTimeout: TimeInterval = 300
    static let screenTimeout: TimeInterval = 120

    @Published var keyboardLocked = false
    @Published var screenCleaning = false
    @Published var permissionMessage: String?

    private var runLoopSource: CFRunLoopSource?
    private var keyboardTimer: Timer?
    private var screenTimer: Timer?
    private var windows: [NSWindow] = []
    private var escMonitor: Any?
    private var sleepActivity: NSObjectProtocol?

    // MARK: Keyboard

    func setKeyboardLocked(_ on: Bool) {
        on ? lockKeyboard() : unlockKeyboard()
    }

    private func lockKeyboard() {
        guard !keyboardLocked else { return }
        // Blocking keys needs two permissions: Accessibility (to modify events) and Input Monitoring (to see keys).
        let ax = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        Self.log("lock requested: accessibility=\(ax) inputMonitoring=\(listen)")
        if !ax { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        if !listen { _ = CGRequestListenEventAccess() }
        if !ax || !listen {
            let missing = [ax ? nil : "Accessibility", listen ? nil : "Input Monitoring"].compactMap { $0 }.joined(separator: " and ")
            // macOS often shows no prompt for an ad-hoc signed app, so open the right Settings pane directly.
            let pane = ax ? "Privacy_ListenEvent" : "Privacy_Accessibility"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
            permissionMessage = "Keyboard cleaning needs \(missing) access: System Settings › Privacy & Security, enable SiliconMonitor there, then try again. If it's already listed, remove it with − and add it again (a rebuilt app needs a fresh grant)."
            return
        }

        // keyDown, keyUp, flagsChanged, and NX_SYSDEFINED (14) for media/brightness/volume keys
        let types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: swallowEvents, userInfo: nil) else {
            Self.log("tapCreate failed")
            permissionMessage = "Couldn't start the keyboard lock (macOS refused the event tap). Remove SiliconMonitor from Accessibility and Input Monitoring, add it again, then try once more."
            return
        }
        permissionMessage = nil
        activeTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.log("tap created, enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        keyboardLocked = true
        keyboardTimer = Timer.scheduledTimer(withTimeInterval: Self.keyboardTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.unlockKeyboard() }
        }
    }

    private static func log(_ line: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("keyboard.log")
        let data = Data("\(Date()) \(line)\n".utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 100_000 {
            try? FileManager.default.removeItem(at: url)   // keep the log small
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    func unlockKeyboard() {
        keyboardTimer?.invalidate(); keyboardTimer = nil
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        runLoopSource = nil
        if let tap = activeTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        activeTap = nil
        keyboardLocked = false
    }

    // MARK: Screen

    func setScreenCleaning(_ on: Bool) {
        on ? startScreen() : stopScreen()
    }

    private func startScreen() {
        guard !screenCleaning else { return }
        let canEsc = !keyboardLocked
        for screen in NSScreen.screens {
            let w = CleaningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: true)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

            let hint = canEsc ? "Screen cleaning  ·  press Esc to exit" : "Screen cleaning  ·  ends automatically"
            let label = NSTextField(labelWithString: "\(hint)  ·  \(Int(Self.screenTimeout / 60)) min max")
            label.textColor = NSColor(white: 0.25, alpha: 1)
            label.font = .systemFont(ofSize: 13)
            label.sizeToFit()
            label.setFrameOrigin(NSPoint(x: (screen.frame.width - label.frame.width) / 2, y: 40))
            w.contentView?.addSubview(label)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSCursor.hide()

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.stopScreen() }; return nil }
            return e
        }
        // Keep the display awake while cleaning.
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                              reason: "Screen cleaning")
        screenCleaning = true
        screenTimer = Timer.scheduledTimer(withTimeInterval: Self.screenTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopScreen() }
        }
    }

    func stopScreen() {
        guard screenCleaning else { return }
        screenTimer?.invalidate(); screenTimer = nil
        if let m = escMonitor { NSEvent.removeMonitor(m) }
        escMonitor = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.unhide()
        screenCleaning = false
    }
}

/// Borderless windows refuse key status by default; the overlay needs it to receive Esc.
private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

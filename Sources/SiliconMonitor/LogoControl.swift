import AppKit

// Control of the illuminated Apple logo on MacBook Pros with a PROLED XDR display.
//
// macOS has no public API for the logo (Apple's documented route is a `sudo defaults write` Terminal command).
// The system's brightness daemon (corebrightnessd) exposes it through the private CoreBrightness framework:
//
//   LEBacklightMode          0 = off, 2 = on
//   LEPWMFactorFadeDuration  seconds for the next fade (0 = automatic, about 0.3 s)
//   DisplayLogicalState      1 = "Blank" (logo fades out), 2 = "Unblank" (fades back in). Writing the state
//                            it is already in is ignored. Blank also dims the keyboard backlight, so every
//                            Blank is followed by a keyboard-only Unblank.
//   LEPWMState["Factor"]     0...1, the logo's current level (read)
//
// There is no brightness property. A fixed level is made by starting a fade and reversing it when it reaches
// the level: a reversal with a huge fade duration (1e9 s) starts a fade that hardly moves, so the logo holds.
// Effects are sequences of timed fades.
//
// The key names and the fade/hold technique are documented by the open-source LogoLight app
// (MIT, github.com/Ark0N/LogoLight); this is an independent implementation. It is private API: it is loaded at
// runtime and everything degrades to "not available" if it is missing.

/// Talks to corebrightnessd. All logo work runs on one serial queue; a newer job makes older ones bail out.
private final class LogoDriver: @unchecked Sendable {
    private typealias KeyboardSetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool

    private let queue = DispatchQueue(label: "siliconmonitor.logo")
    private let lock = NSLock()
    private var latest = 0                 // job counter; a job is "alive" while it is still the newest
    private var heading: Bool?             // queue-confined: direction of the last fade we started (true = lit)

    private let client: NSObject
    private let getSel = NSSelectorFromString("copyPropertyForKey:")
    private let setSel = NSSelectorFromString("setProperty:forKey:")
    private let keyboardSetSel = NSSelectorFromString("setProperty:withKey:keyboardID:")
    private let keyboardSet: KeyboardSetFn?
    private let keyboardIDs: [UInt64]

    static let holdDuration = 1e9

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else { return nil }
        let c = cls.init()
        guard c.responds(to: getSel), c.responds(to: setSel) else { return nil }
        client = c
        if c.responds(to: keyboardSetSel), let imp = c.method(for: keyboardSetSel) {
            keyboardSet = unsafeBitCast(imp, to: KeyboardSetFn.self)
        } else {
            keyboardSet = nil
        }
        let ids = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type).map { $0.init() }
            .flatMap { kb -> [NSNumber]? in
                let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
                return kb.responds(to: sel) ? kb.perform(sel)?.takeRetainedValue() as? [NSNumber] : nil
            }
        keyboardIDs = (ids ?? []).map { $0.uint64Value }
    }

    // MARK: Jobs

    /// Runs `job` on the logo queue. It receives `alive`, which turns false as soon as a newer job is submitted.
    func submit(_ job: @escaping (_ alive: () -> Bool) -> Void) {
        lock.lock(); latest += 1; let mine = latest; lock.unlock()
        queue.async { [self] in
            job { lock.lock(); defer { lock.unlock() }; return latest == mine }
        }
    }

    /// Cancels whatever is running, restores automatic brightness and waits for it (used when quitting).
    func restoreAndWait() {
        lock.lock(); latest += 1; lock.unlock()
        queue.sync { restore() }
    }

    // MARK: Primitives (call only from the queue, except the reads)

    func readMode() -> Int? {
        (client.perform(getSel, with: "LEBacklightMode")?.takeRetainedValue() as? NSNumber)?.intValue
    }

    func writeMode(_ mode: Int) {
        _ = client.perform(setSel, with: NSNumber(value: mode), with: "LEBacklightMode")
    }

    func factor() -> Double {
        let state = client.perform(getSel, with: "LEPWMState")?.takeRetainedValue() as? [String: Any]
        return (state?["Factor"] as? NSNumber)?.doubleValue ?? -1
    }

    private func setFade(_ seconds: Double) {
        _ = client.perform(setSel, with: NSNumber(value: max(0, seconds)), with: "LEPWMFactorFadeDuration")
    }

    private func setLit(_ lit: Bool) {
        _ = client.perform(setSel, with: NSNumber(value: lit ? 2 : 1), with: "DisplayLogicalState")
        heading = lit
        if !lit, let keyboardSet {   // Blank dims the keyboard too; light it again straight away
            for id in keyboardIDs { _ = keyboardSet(client, keyboardSetSel, NSNumber(value: 2), "DisplayLogicalState", id) }
        }
    }

    /// Starts a near-frozen fade in the opposite direction, which holds the logo where it is.
    private func turnRound(from up: Bool) {
        setFade(Self.holdDuration)
        setLit(!up)
    }

    /// Back to Apple's automatic behaviour (follows the screen). Blank then Unblank, because writing the state
    /// the logo is already in would be ignored.
    func restore() {
        setFade(0)
        setLit(false)
        setLit(true)
    }

    private func sleep(_ seconds: Double, alive: () -> Bool) {
        var left = seconds
        while left > 0, alive() {
            let step = min(left, 0.02)
            Thread.sleep(forTimeInterval: step)
            left -= step
        }
    }

    // MARK: Brightness level

    /// Holds the logo at `target` (0...1): start a slow fade toward it, poll the level, reverse when it arrives.
    func hold(at target: Double, alive: () -> Bool) {
        let target = min(max(target, 0), 1)
        let current = factor()
        guard current >= 0, abs(target - current) >= 0.005 else { return }
        let up = target > current
        if heading == nil || heading == up { turnRound(from: up) }   // a write only starts a fade when the direction changes
        let fadeSeconds = 4.0                                         // slow, so the stop is accurate
        setFade(fadeSeconds)
        setLit(up)
        let started = Date()
        while alive(), Date().timeIntervalSince(started) < fadeSeconds * 1.5 {
            let f = factor()
            if up ? f >= target : f <= target { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard alive() else { return }   // superseded: the newer job takes over from wherever the logo is
        turnRound(from: up)
    }

    // MARK: Effects

    /// Waits (polling the logo's level) until `reached` is true, `timeout` passes, or the job is superseded.
    private func wait(timeout: Double, alive: () -> Bool, until reached: (Double) -> Bool) {
        let started = Date()
        while alive(), Date().timeIntervalSince(started) < timeout {
            if reached(factor()) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// The daemon's fade is a critically damped spring: progress(s) = 1 - (1 + k s) e^(-k s) for s = elapsed /
    /// duration, k = 6.51 (measured by LogoLight). This returns the s at which `progress` of the travel is covered,
    /// so a fade can be asked for with a duration that reaches a chosen level in a chosen time.
    static func timeFraction(toReach progress: Double) -> Double {
        let k = 6.51, target = min(max(progress, 0.01), 0.995)
        var lo = 0.0, hi = 1.5
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            (1 - (1 + k * mid) * exp(-k * mid) < target) ? (lo = mid) : (hi = mid)
        }
        return (lo + hi) / 2
    }

    struct Step {
        let lit: Bool        // true = brighten to full, false = fade down to the floor
        let time: Double     // seconds to get there
        let hold: Double     // pause at the top after brightening (a fall is reversed straight away)
    }

    /// Plays a repeating cycle of rises to full and falls to `floor`. The logo never goes darker than the floor:
    /// each fall is asked to run long enough to land there in `time` seconds, then reversed by watching the level.
    /// The fade eases to a stop, so reversing late in it is gentle.
    func effect(floor: Double, steps: [Step], alive: () -> Bool) {
        restore()                                 // start from a known state: lit, automatic
        sleep(0.45, alive: alive)
        // The logo is lit, so begin with a fall (a same-state write would be ignored).
        var cycle = steps
        if let i = cycle.firstIndex(where: { !$0.lit }) { cycle = Array(cycle[i...] + cycle[..<i]) }
        let top = 0.97
        while alive() {
            for step in cycle {
                guard alive() else { return }
                let now = max(factor(), 0.01)
                if step.lit {
                    let progress = (top - now) / max(1 - now, 0.01)           // share of the way to full
                    let duration = step.time / Self.timeFraction(toReach: progress)
                    setFade(duration)
                    setLit(true)
                    wait(timeout: duration + 1, alive: alive) { $0 >= top }
                    sleep(step.hold, alive: alive)
                } else {
                    let progress = (now - floor) / now                        // share of the way to dark
                    let duration = step.time / Self.timeFraction(toReach: progress)
                    setFade(duration)
                    setLit(false)
                    wait(timeout: duration + 1, alive: alive) { $0 <= floor }
                }
            }
        }
    }
}

@MainActor
final class LogoControl: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, breathe, pulse, heartbeat, dim
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .breathe: return "Breathe"
            case .pulse: return "Pulse"
            case .heartbeat: return "Beat"
            case .dim: return "Dim"
            }
        }
    }

    @Published private(set) var available = false
    @Published private(set) var isOn = true
    @Published private(set) var mode: Mode = .auto
    /// Slider position for Dim, 0.1...1. The logo's level follows a gentle curve of it.
    @Published private(set) var dim: Double

    private var driver: LogoDriver?
    private var pendingDim: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        let saved = UserDefaults.standard.object(forKey: "logoDim") as? Double
        dim = min(max(saved ?? 0.5, 0.1), 1)
        guard let d = LogoDriver(), let current = d.readMode() else { return }   // no value = no illuminated logo
        driver = d
        available = true
        isOn = current != 0

        // A crash while holding a level leaves a huge fade duration in the daemon; recover if the logo looks stuck.
        d.submit { _ in
            if d.readMode() != 0, d.factor() >= 0, d.factor() < 0.97 { d.restore() }
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.driver?.submit { _ in } }   // stop effects while the screen sleeps
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode != .auto else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { self.apply(self.mode) } }
            }
        })
    }

    /// Re-reads the real on/off state (it can be changed from Terminal or another app).
    func refresh() {
        guard let d = driver, let m = d.readMode() else { return }
        isOn = m != 0
    }

    func setOn(_ on: Bool) {
        guard let d = driver else { return }
        pendingDim?.cancel()
        if on {
            d.submit { _ in d.writeMode(2) }
        } else {
            mode = .auto
            d.submit { _ in d.restore(); d.writeMode(0) }   // leave nothing held or animating when going dark
        }
        isOn = on
    }

    func setMode(_ new: Mode) {
        guard available, isOn else { return }
        mode = new
        apply(new)
    }

    func setDim(_ value: Double) {
        dim = min(max(value, 0.1), 1)
        UserDefaults.standard.set(dim, forKey: "logoDim")
        guard mode == .dim else { return }
        pendingDim?.cancel()
        pendingDim = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)   // wait for the slider to settle
            guard !Task.isCancelled else { return }
            apply(.dim)
        }
    }

    private func apply(_ mode: Mode) {
        guard let d = driver else { return }
        switch mode {
        case .auto:
            d.submit { _ in d.restore() }
        case .breathe:   // slow and soft, like the old MacBook sleep light: about 9 s a breath, floor 15%
            d.submit { alive in
                d.effect(floor: 0.15, steps: [LogoDriver.Step(lit: false, time: 3.3, hold: 0),
                                              LogoDriver.Step(lit: true, time: 4.5, hold: 0.3)], alive: alive)
            }
        case .pulse:     // a quicker swell, floor 35%
            d.submit { alive in
                d.effect(floor: 0.35, steps: [LogoDriver.Step(lit: false, time: 0.8, hold: 0),
                                              LogoDriver.Step(lit: true, time: 1.1, hold: 0.15)], alive: alive)
            }
        case .heartbeat: // two quick beats, then a rest, floor 25%
            d.submit { alive in
                d.effect(floor: 0.25, steps: [LogoDriver.Step(lit: true, time: 0.12, hold: 0.04),
                                              LogoDriver.Step(lit: false, time: 0.15, hold: 0),
                                              LogoDriver.Step(lit: true, time: 0.12, hold: 0.04),
                                              LogoDriver.Step(lit: false, time: 0.5, hold: 0)], alive: alive)
            }
        case .dim:
            let level = 0.02 + 0.98 * dim * dim              // gentle curve so the low end isn't all bunched up
            d.submit { alive in
                if level >= 0.97 { d.restore() } else { d.hold(at: level, alive: alive) }
            }
        }
    }

    /// Quitting: hand the logo back to the system.
    func shutdown() {
        pendingDim?.cancel()
        driver?.restoreAndWait()
        mode = .auto
    }

    // MARK: Debug

    /// `SiliconMonitor --logo-selftest`: runs each mode briefly and prints the logo's level, then restores.
    func selfTest() {
        guard let d = driver else { print("logo not available"); return }
        func sample(_ label: String, seconds: Double, every: Double = 0.4) {
            var values: [String] = []
            var t = 0.0
            while t < seconds { Thread.sleep(forTimeInterval: every); t += every; values.append(String(format: "%.2f", d.factor())) }
            print("\(label): \(values.joined(separator: " "))")
        }
        func range(_ label: String, seconds: Double, every: Double) {
            var low = 9.0, high = -1.0, t = 0.0
            while t < seconds { Thread.sleep(forTimeInterval: every); t += every; let f = d.factor(); low = min(low, f); high = max(high, f) }
            print(String(format: "%@: lowest %.2f, highest %.2f", label, low, high))
        }
        setMode(.breathe); sample("breathe", seconds: 12.0, every: 0.5); range("breathe", seconds: 20, every: 0.05)
        setMode(.pulse); sample("pulse", seconds: 4.0, every: 0.2); range("pulse", seconds: 12, every: 0.02)
        setMode(.heartbeat); sample("heartbeat", seconds: 3.2, every: 0.1); range("heartbeat", seconds: 10, every: 0.02)
        setDim(0.5); setMode(.dim)
        Thread.sleep(forTimeInterval: 0.3)
        sample(String(format: "dim 50%% -> level %.2f", 0.02 + 0.98 * 0.25), seconds: 6.0, every: 0.8)
        setDim(0.25); pendingDim?.cancel(); apply(.dim)   // (no run loop here, so skip the slider debounce)
        sample(String(format: "dim 25%% -> level %.2f", 0.02 + 0.98 * 0.0625), seconds: 6.0, every: 0.8)
        setMode(.auto); Thread.sleep(forTimeInterval: 1.2)
        print(String(format: "auto again: %.2f", d.factor()))
        shutdown()
    }
}

import AppKit
import Darwin

// Small system toggles for the Tools grid: dark mode, keyboard backlight, desktop icons.

// MARK: - Keyboard backlight (private CoreBrightness)

/// On/off for the keyboard backlight through the private `KeyboardBrightnessClient`. "Off" turns auto-brightness
/// off and the level to 0; "on" restores the level and the auto-brightness setting it had.
private final class KeyboardBacklight {
    private typealias GetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias GetBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetFloat = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias SetBool = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private let client: NSObject
    private let ids: [UInt64]
    private let brightnessSel = NSSelectorFromString("brightnessForKeyboard:")
    private let setBrightnessSel = NSSelectorFromString("setBrightness:forKeyboard:")
    private let autoSel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
    private let setAutoSel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let c = cls.init()
        guard [brightnessSel, setBrightnessSel, autoSel, setAutoSel].allSatisfy({ c.responds(to: $0) }),
              let list = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
              !list.isEmpty else { return nil }
        client = c
        ids = list.map { $0.uint64Value }
    }

    private func imp<T>(_ sel: Selector, as type: T.Type) -> T { unsafeBitCast(client.method(for: sel), to: type) }

    var brightness: Float { imp(brightnessSel, as: GetFloat.self)(client, brightnessSel, ids[0]) }
    var autoBrightness: Bool { imp(autoSel, as: GetBool.self)(client, autoSel, ids[0]) }
    /// True while the system is holding the backlight off (e.g. it was switched to Auto while dark, and stays that way).
    var suppressed: Bool {
        let sel = NSSelectorFromString("isBacklightSuppressedOnKeyboard:")
        return client.responds(to: sel) ? imp(sel, as: GetBool.self)(client, sel, ids[0]) : false
    }

    func set(brightness: Float) {
        let f = imp(setBrightnessSel, as: SetFloat.self)
        for id in ids { _ = f(client, setBrightnessSel, brightness, id) }
    }

    func set(autoBrightness on: Bool) {
        let f = imp(setAutoSel, as: SetBool.self)
        for id in ids { _ = f(client, setAutoSel, on, id) }
    }
}

// MARK: - The toggles

/// How the keyboard backlight is being driven.
enum KeyLightMode: String {
    case auto   // the ambient light sensor decides (it may well be dark in a bright room)
    case on     // a fixed level, sensor off
    case off    // dark, sensor off so it stays dark

    var title: String { switch self { case .auto: return "Auto"; case .on: return "On"; case .off: return "Off" } }
    var next: KeyLightMode { switch self { case .auto: return .on; case .on: return .off; case .off: return .auto } }
}

@MainActor
final class SystemToggles: ObservableObject {
    private typealias GetTheme = @convention(c) () -> Bool
    private typealias SetTheme = @convention(c) (Bool) -> Void

    @Published private(set) var isDark = false
    @Published private(set) var iconsHidden = false
    @Published private(set) var keyLightAvailable = false
    @Published private(set) var keyLight = KeyLightMode.auto

    private let getTheme: GetTheme?
    private let setTheme: SetTheme?
    private let keyboard = KeyboardBacklight()

    init() {
        // Dark mode: SkyLight's legacy appearance switch (private, but needs no permission prompt).
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        getTheme = handle.flatMap { dlsym($0, "SLSGetAppearanceThemeLegacy") }.map { unsafeBitCast($0, to: GetTheme.self) }
        setTheme = handle.flatMap { dlsym($0, "SLSSetAppearanceThemeLegacy") }.map { unsafeBitCast($0, to: SetTheme.self) }
        keyLightAvailable = keyboard != nil
        refresh()
    }

    var darkModeAvailable: Bool { getTheme != nil && setTheme != nil }

    /// Re-reads every state (any of them can be changed outside the app).
    func refresh() {
        if let getTheme { isDark = getTheme() }
        iconsHidden = !((CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool) ?? true)
        if let keyboard { keyLight = currentKeyLight(keyboard) }
    }

    // MARK: Dark mode

    func setDark(_ dark: Bool) {
        guard let setTheme else { return }
        setTheme(dark)
        isDark = getTheme?() ?? dark
    }

    // MARK: Keyboard backlight

    private func currentKeyLight(_ keyboard: KeyboardBacklight) -> KeyLightMode {
        if keyboard.autoBrightness { return .auto }
        return keyboard.brightness > 0.01 ? .on : .off
    }

    /// Auto: the sensor drives it. On: a fixed level (the one you last had), sensor off. Off: dark, sensor off.
    func setKeyLight(_ mode: KeyLightMode) {
        guard let keyboard else { return }
        let defaults = UserDefaults.standard
        let level = keyboard.brightness
        if level > 0.01 { defaults.set(level, forKey: "keyLightLevel") }   // remember a real level for next time
        switch mode {
        case .auto:
            // Switching to Auto while the level is 0 leaves the system holding the light off for good ("suppressed"),
            // so give the sensor a lit starting point first and let it take over from there.
            if level <= 0.01 { keyboard.set(brightness: max(defaults.object(forKey: "keyLightLevel") as? Float ?? 0.5, 0.15)) }
            keyboard.set(autoBrightness: true)
        case .on:
            keyboard.set(autoBrightness: false)
            keyboard.set(brightness: max(defaults.object(forKey: "keyLightLevel") as? Float ?? 0.5, 0.15))
        case .off:
            keyboard.set(autoBrightness: false)     // otherwise the sensor would turn it straight back on
            keyboard.set(brightness: 0)
        }
        keyLight = currentKeyLight(keyboard)
    }

    // MARK: Desktop icons

    func setIconsHidden(_ hidden: Bool) {
        CFPreferencesSetAppValue("CreateDesktop" as CFString, NSNumber(value: !hidden), "com.apple.finder" as CFString)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        iconsHidden = hidden
        // Finder reads this at launch, so restart it (its windows reopen on their own).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Debug

    /// `SiliconMonitor --tools-selftest`: exercises dark mode and the keyboard backlight and prints what it reads back.
    func selfTest() {
        print("dark mode available:", darkModeAvailable, " now dark:", isDark, " keyboard light available:", keyLightAvailable,
              " icons hidden:", iconsHidden)
        if darkModeAvailable {
            let before = isDark
            setDark(!before); Thread.sleep(forTimeInterval: 2)
            print("dark mode: \(before) -> \(isDark) | defaults says:", UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "Light")
            setDark(before); Thread.sleep(forTimeInterval: 1)
            print("dark mode restored:", isDark)
        }
        if keyLightAvailable, let kb = keyboard {
            let start = keyLight
            func show(_ label: String) {
                print(String(format: "keyboard %@ -> level %.2f, auto %@, suppressed %@, tile says %@", label, kb.brightness,
                             kb.autoBrightness ? "yes" : "no", kb.suppressed ? "YES" : "no", keyLight.title))
            }
            show("start")
            for mode in [KeyLightMode.on, .off, .auto] { setKeyLight(mode); Thread.sleep(forTimeInterval: 3); show("set \(mode.title)") }
            setKeyLight(start); Thread.sleep(forTimeInterval: 3); show("restored to \(start.title)")
        }
    }
}

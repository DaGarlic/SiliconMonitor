import SwiftUI
import Combine
import Foundation

@main
enum Entry {
    @MainActor static func main() {
        // `SiliconMonitor --dump` prints one reading and exits, for checking sensors without the UI.
        if CommandLine.arguments.contains("--dump") {
            let m = Monitor()
            Thread.sleep(forTimeInterval: 1)
            m.refresh()
            print("SMC available: \(m.smcAvailable)")
            print(String(format: "CPU %.1f%%  GPU %.1f%%", m.cpu, m.gpu))
            print("CPU temp: \(m.cpuTemp.map { String(format: "%.1f°C", $0) } ?? "n/a")")
            print("GPU temp: \(m.gpuTemp.map { String(format: "%.1f°C", $0) } ?? "n/a")")
            print(String(format: "Disk: read %@  write %@  free %.0f of %.0f GB", Monitor.rate(m.diskRead), Monitor.rate(m.diskWrite),
                         Double(m.diskFree) / 1e9, Double(m.diskTotal) / 1e9))
            print("Battery: health \(m.batteryHealth.map { String(format: "%.0f%%", $0) } ?? "n/a"), cycles \(m.cycleCount.map(String.init) ?? "n/a")")
            print(String(format: "Memory: %.1f of %.0f GB, swap %.1f GB, pressure level %d", Double(m.memUsed) / 1_073_741_824, Double(m.memTotal) / 1_073_741_824,
                         Double(m.swapUsed) / 1_073_741_824, m.memPressure))
            print(String(format: "Network: down %@  up %@   Power: %@ W (adapter %@ W)", Monitor.rate(m.netDown), Monitor.rate(m.netUp),
                         m.systemPower.map { String(format: "%.1f", $0) } ?? "n/a", m.adapterPower.map { String(format: "%.1f", $0) } ?? "n/a"))
            print("Fans: \(m.fans.map { String(format: "#%d %.0f rpm (min %.0f, max %.0f)", $0.id, $0.rpm, $0.min, $0.max) })")
            exit(0)
        }
        if CommandLine.arguments.contains("--tools-selftest") {   // debug: dark mode and keyboard backlight round trip
            SystemToggles().selfTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--layout-selftest") {   // debug: card height with and without a height cap
            _ = NSApplication.shared
            let monitor = Monitor()
            monitor.refresh()
            let view = ContentView(onQuit: {}).environmentObject(monitor).environmentObject(CleaningMode()).environmentObject(PowerMode())
                .environmentObject(FanController()).environmentObject(LogoControl()).environmentObject(SystemToggles())
                .environmentObject(UpdateChecker()).environmentObject(monitor.throttle)
            for cap in [10_000.0, 500.0] {
                CardStyle.maxHeight = cap
                let host = NSHostingView(rootView: view)
                host.layoutSubtreeIfNeeded()
                print("cap \(Int(cap)): fitting height \(host.fittingSize.height)")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--throttle-selftest") {   // debug: prints what the throttle detector sees for 12 s
            let t = ThrottleMonitor()
            print("available: \(t.available)")
            var r = ThrottleReading(); r.gpuLoad = 90
            print("clean:", r.causes)
            r.thermalLevel = 2; r.gpuCLTM = 0.4; print("hot:", r.causes)
            r = ThrottleReading(); r.gpuLoad = 90; r.gpuReason = "GPU3_EMT"; r.gpuReasonShare = 0.2; r.gpuBudget = 0.5; r.gpuPowerCtl = 0.3
            print("emergency + power:", r.causes)
            r = ThrottleReading(); r.gpuLoad = 5; r.gpuBudget = 0.5; print("idle low budget:", r.causes)
            for i in 0..<12 {
                Thread.sleep(forTimeInterval: 1)
                t.tick(cpuLoad: 0, gpuLoad: 0, cpuTemp: nil, gpuTemp: nil, power: nil)
                let clocks = t.clocks.map { String(format: "%@ %.0f/%.0f MHz (%.0f%% active)", $0.name, $0.mhz, $0.maxMHz, $0.active * 100) }
                print("\(i): thermal \(t.thermalLevel), budget \(Int(t.gpuBudget * 100))%, causes \(t.causes), \(clocks.joined(separator: "; "))")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--music-selftest") {   // debug: Music mode for 10 s, prints the logo's level range
            let logo = LogoControl()
            logo.setMode(.music)
            var low = 9.0, high = -1.0, flashes = 0, wasHigh = false
            for _ in 0..<1000 {
                Thread.sleep(forTimeInterval: 0.01)
                let f = logo.debugLevel
                low = min(low, f); high = max(high, f)
                if f > 0.5 && !wasHigh { flashes += 1 }
                wasHigh = f > 0.5
            }
            print(String(format: "mode %@, level lowest %.2f highest %.2f, flashes above 50%%: %d", logo.mode.rawValue, low, high, flashes))
            logo.shutdown()
            exit(0)
        }
        if CommandLine.arguments.contains("--logo-selftest") {   // debug: runs every logo mode and prints the level
            LogoControl().selfTest()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--keys"), i + 1 < CommandLine.arguments.count {
            dumpSMCKeys(prefix: CommandLine.arguments[i + 1])   // debug: list SMC keys with a prefix
            exit(0)
        }
        if CommandLine.arguments.contains("--install-fan-helper") {   // debug: run the one-time install from a shell
            print(FanController.installHelper() ? "installed" : "install failed or cancelled")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--fan-helper"), CommandLine.arguments.count > i + 2 {
            runFanHelper(socketPath: CommandLine.arguments[i + 1], uid: uid_t(CommandLine.arguments[i + 2]) ?? getuid())
        }
        // Plain AppKit lifecycle: only the menu bar item and its card, no SwiftUI scenes (so no Settings window).
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - App delegate: status item + rounded card

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let cleaning = CleaningMode()
    let power = PowerMode()
    let fanControl = FanController()
    let logo = LogoControl()
    let tools = SystemToggles()
    let updates = UpdateChecker()

    private var statusItem: NSStatusItem!
    private var card: CardPanel!
    private var host: RoundedHostingView<AnyView>!
    private var cardContent: AnyView!   // swapped in only while the card is open, so a hidden card costs nothing
    private var cardShown = false
    private var lastToggle = Date.distantPast
    private var outsideClick: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(clicked(_:))
        }

        cardContent = AnyView(ContentView(onQuit: { [weak self] in self?.quit() })
            .environmentObject(monitor)
            .environmentObject(cleaning)
            .environmentObject(power)
            .environmentObject(fanControl)
            .environmentObject(logo)
            .environmentObject(tools)
            .environmentObject(updates)
            .environmentObject(monitor.throttle))
        let made = CardWindow.make(AnyView(EmptyView()))
        card = made.panel
        host = made.host
        card.onCancel = { [weak self] in self?.hide() }
        host.onContentSizeChange = { [weak self] in DispatchQueue.main.async { self?.fitCard() } }

        // Menu bar readout and card height update once per refresh (not once per changed value), and the
        // menu bar image is only redrawn when its text actually changed.
        monitor.onRefresh = { [weak self] in self?.updateStatusItem(); self?.fitCard() }
        // Setting toggles change the text immediately, between refreshes.
        monitor.$showCPU.merge(with: monitor.$showGPU, monitor.$showCPUTemp, monitor.$showGPUTemp, monitor.$showFan, monitor.$showDisk)
            .dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &cancellables)
        for o in [cleaning.objectWillChange, power.objectWillChange, fanControl.objectWillChange, logo.objectWillChange, tools.objectWillChange] {
            o.receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.fitCard() }
            }.store(in: &cancellables)
        }
        // Get out of the way when the screen goes black.
        cleaning.$screenCleaning.removeDuplicates().filter { $0 }.sink { [weak self] _ in self?.hide() }
            .store(in: &cancellables)

        // Behave like a transient popover: clicking elsewhere, or switching apps, closes the card.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cardShown else { return }
                let anchor = self.statusItem.button?.window?.frame ?? .zero
                if CardPlacement.isInsideAny(NSEvent.mouseLocation, [anchor, self.card.frame]) { return }
                self.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cardShown, !self.card.isKeyWindow else { return }
                self.hide()
            }
        }

        monitor.start()
        updates.start()
        updateStatusItem()
        // Debug aid: SILICONMONITOR_SHOW_CARD=1 opens the card shortly after launch (for screenshots/measuring).
        if ProcessInfo.processInfo.environment["SILICONMONITOR_SHOW_CARD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.show() }
        }
    }

    private var lastTitle: String?

    func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        // Orange while macOS is limiting performance, so throttling shows without opening the card.
        let tint: NSColor? = monitor.throttle.limited ? .systemOrange : nil
        if b.contentTintColor != tint { b.contentTintColor = tint }
        let title = monitor.menuTitle
        guard title != lastTitle else { return }
        lastTitle = title
        if title.isEmpty {
            let img = NSImage(systemSymbolName: "cpu", accessibilityDescription: "SiliconMonitor")
            img?.isTemplate = true
            b.image = img
        } else {
            b.image = menuBarImage(monitor.menuCells)
        }
    }

    @objc func clicked(_ sender: Any?) {
        if Date().timeIntervalSince(lastToggle) < 0.22 { return }
        lastToggle = Date()
        cardShown ? hide() : show()
    }

    private var fittingHeight: CGFloat {
        host.layoutSubtreeIfNeeded()
        return ceil(host.fittingSize.height)
    }

    /// Resize the card to its content, keeping its top edge where it is.
    func fitCard() {
        guard cardShown else { return }
        let h = fittingHeight
        guard abs(h - card.frame.height) > 1 else { return }
        var f = card.frame
        f.origin.y += f.height - h
        f.size.height = h
        animateCard(to: f)
    }

    private var resizeTimer: Timer?

    /// Moves the card to `target` over 0.2 s, setting position and size together on every tick. (AppKit's own
    /// animator ran the size ahead of the position, so the card briefly grew upward instead of staying pinned
    /// under the menu bar.) Matches the 0.2 s ease-out of the SwiftUI animations inside.
    private func animateCard(to target: NSRect) {
        resizeTimer?.invalidate()
        resizeTimer = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            card.setFrame(target, display: true)
            return
        }
        let start = card.frame
        let began = Date()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(began) / 0.2)
                let e = CGFloat(1 - (1 - t) * (1 - t))                      // ease-out
                func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
                self.card.setFrame(NSRect(x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                                          width: mix(start.width, target.width), height: mix(start.height, target.height)),
                                   display: true)
                if t >= 1 { timer.invalidate(); self.resizeTimer = nil }
            }
        }
    }

    func show() {
        guard let anchor = statusItem.button?.window?.frame else { return }
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        CardStyle.maxHeight = max(anchor.minY - CardStyle.gap - screen.minY - 8, 300)   // the card scrolls beyond this
        monitor.refresh()
        logo.refresh()
        tools.refresh()
        host.rootView = cardContent
        host.invalidateIntrinsicContentSize()   // the height cap may have changed (another screen)
        let frame = CardPlacement.frame(anchor: anchor, screen: screen,
                                        size: NSSize(width: CardStyle.width, height: fittingHeight))
        cardShown = true
        NSApp.activate(ignoringOtherApps: true)
        CardWindow.present(card, at: frame)
    }

    func hide() {
        guard cardShown else { return }
        cardShown = false
        CardWindow.dismiss(card)
        // Once the fade-out has finished, drop the card's view tree so it stops updating while hidden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.cardShown else { return }
                self.host.rootView = AnyView(EmptyView())
            }
        }
    }

    func quit() {
        Task {
            fanControl.shutdown()
            logo.shutdown()
            cleaning.unlockKeyboard(); cleaning.stopScreen()
            await power.restoreBeforeQuit()
            NSApp.terminate(nil)
        }
    }
}

/// Draws the readout as compact stacked cells (a tiny label over the value) in one template image, so it follows the
/// menu bar's light/dark colouring. Each cell has a fixed width, so the text never shifts as the numbers change.
func menuBarImage(_ cells: [Monitor.MenuCell]) -> NSImage {
    let labelFont = NSFont.systemFont(ofSize: 6.5, weight: .semibold)
    let valueFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black.withAlphaComponent(0.6),
                                                     .kern: 0.3]
    let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
    let gap: CGFloat = 7
    let widths = cells.map { max(NSAttributedString(string: $0.sample, attributes: valueAttrs).size().width,
                                 NSAttributedString(string: $0.label, attributes: labelAttrs).size().width).rounded(.up) }
    let total = widths.reduce(0, +) + gap * CGFloat(max(cells.count - 1, 0))
    let size = NSSize(width: max(total, 1), height: 22)
    let img = NSImage(size: size, flipped: false) { rect in
        var x: CGFloat = 0
        for (cell, w) in zip(cells, widths) {
            let l = NSAttributedString(string: cell.label, attributes: labelAttrs)
            let v = NSAttributedString(string: cell.value, attributes: valueAttrs)
            l.draw(at: NSPoint(x: x + (w - l.size().width) / 2, y: rect.height - l.size().height - 1.5))
            v.draw(at: NSPoint(x: x + (w - v.size().width) / 2, y: 1))   // right-aligned digits would jitter; centre instead
            x += w + gap
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Card content

enum Theme {
    static let subtleFill = Color.primary.opacity(0.06)
    static let hairline = Color.primary.opacity(0.10)
}

/// Scrolls its child vertically and sizes itself to the child's natural height, but never taller than
/// `CardStyle.maxHeight` (what fits on the screen under the menu bar); beyond that the content scrolls.
/// While the card animates its height the window is briefly shorter or taller than the content; the scroll view
/// fills whatever it is given and keeps the content pinned to the top, so nothing drifts.
struct FitScroll: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        return CGSize(width: ideal.width, height: min(ideal.height, CardStyle.maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A tiled toggle: icon and label on a rounded tile that fills with the accent colour when on.
struct Tile: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let isOn: Bool
    var disabled = false
    var inline = false    // slim pill with the icon beside the label, for toggles that only need a name
    var isAction = false  // a one-shot action rather than an on/off toggle: the icon is tinted so it reads as "do this"
    var compact = true   // shorter tile with tighter padding and text (false gives the roomier original size)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if inline {
                    HStack(spacing: 5) {
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                        Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Image(systemName: icon).font(.system(size: compact ? 13 : 14, weight: .semibold))
                            .foregroundStyle(isAction && !isOn ? Color.accentColor : (isOn ? Color.white : Color.primary))
                        Spacer(minLength: compact ? 2 : 6)
                        Text(title).font(.system(size: compact ? 10 : 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        if subtitle != "" {
                            Text(subtitle ?? (isOn ? "On" : "Off"))
                                .font(.system(size: 10)).opacity(0.75).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .padding(compact ? 6 : 8)
                    .frame(maxWidth: .infinity, minHeight: compact ? 44 : 46, alignment: .leading)
                }
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: inline ? 11 : 14, style: .continuous)
                .fill(isOn ? Color.accentColor : Theme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: inline ? 11 : 14, style: .continuous)
                .strokeBorder(isOn ? Color.clear : Theme.hairline))
            .opacity(disabled ? 0.5 : 1)
            .contentShape(RoundedRectangle(cornerRadius: inline ? 11 : 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Monitor
    @EnvironmentObject var c: CleaningMode
    @EnvironmentObject var p: PowerMode
    @EnvironmentObject var f: FanController
    @EnvironmentObject var l: LogoControl
    @EnvironmentObject var t: SystemToggles
    @EnvironmentObject var u: UpdateChecker
    @EnvironmentObject var th: ThrottleMonitor
    let onQuit: () -> Void
    @AppStorage("menuBarOptionsOpen") private var menuBarOpen = false

    private let five = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)   // menu bar toggles are slim pills, three per row
    private let four = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        FitScroll { ScrollView(.vertical) { mainStack } }
    }

    private var mainStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let v = u.latestVersion {
                Button(action: { u.openDownload() }) {
                    Label("Version \(v) is available. Click to download.", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Opens the release page on GitHub. You are on \(UpdateChecker.currentVersion).")
            }
            throttleBanner
            networkSection
            batterySection
            HStack(alignment: .top, spacing: 10) {   // side by side: the two graphs share one row
                graph("CPU", value: m.cpu, temp: m.cpuTemp, history: m.cpuHistory, color: .blue)
                graph("GPU", value: m.gpu, temp: m.gpuTemp, history: m.gpuHistory, color: .green)
                    .help(String(format: "%d GPU cores. Render %.0f%%  Tiler %.0f%%", m.gpuCoreCount, m.gpuRenderer, m.gpuTiler))
            }
            coreBars
            HStack(alignment: .top, spacing: 10) {   // power and clock speed side by side
                powerSection
                clocksSection
            }
            if f.manual || !m.smcAvailable || m.fans.isEmpty { fansSection }   // in Auto the rpm shows in the control row
            fanControlRow
            memorySection
            diskSection

            section("Tools") {
                LazyVGrid(columns: four, spacing: 6) {   // four per row; more tools wrap onto further rows
                    Tile(icon: "keyboard", title: "Keys", subtitle: c.keyboardLocked ? "Locked" : "Clean…", isOn: c.keyboardLocked, isAction: true) {
                        c.setKeyboardLocked(!c.keyboardLocked)
                    }
                    .help("Keyboard cleaning: locks all keys for up to 5 minutes")
                    Tile(icon: "display", title: "Screen", subtitle: c.screenCleaning ? "Black" : "Clean…", isOn: c.screenCleaning, isAction: true) {
                        c.setScreenCleaning(!c.screenCleaning)
                    }
                    .help("Screen cleaning: blacks out the screen for up to 2 minutes (Esc exits)")
                    Tile(icon: "sun.max", title: "Stay on", isOn: p.keepScreenOn) { p.setKeepScreenOn(!p.keepScreenOn) }
                        .help("Stay on: keeps the display from sleeping")
                    Tile(icon: "laptopcomputer", title: "Lid", subtitle: p.busy ? "Wait…" : (p.lidAwake ? "Awake" : "Sleeps"),
                         isOn: p.lidAwake, disabled: p.busy) { p.setLidAwake(!p.lidAwake) }
                        .help("Lid: keeps the Mac awake with the lid closed (uses the background helper; one admin password the first time)")
                    if l.available {
                        Tile(icon: "applelogo", title: "Logo", subtitle: l.isOn ? "Lit" : "Off", isOn: l.isOn) { l.setOn(!l.isOn) }
                            .help("The glowing Apple logo on the lid. Modes and brightness are below.")
                    }
                    if t.darkModeAvailable {
                        Tile(icon: t.isDark ? "moon.fill" : "sun.max.fill", title: "Dark", subtitle: t.isDark ? "On" : "Light", isOn: t.isDark) {
                            t.setDark(!t.isDark)
                        }
                        .help("Dark or light appearance for the whole Mac")
                    }
                    if t.keyLightAvailable {
                        Tile(icon: "light.max", title: "Key light", subtitle: t.keyLight.title, isOn: t.keyLight != .off) {
                            t.setKeyLight(t.keyLight.next)
                        }
                        .help("Keyboard backlight. Tap to cycle: Auto (ambient sensor), On (fixed level), Off.")
                    }
                    Tile(icon: "eye.slash", title: "Icons", subtitle: t.iconsHidden ? "Hidden" : "Shown", isOn: t.iconsHidden) {
                        t.setIconsHidden(!t.iconsHidden)
                    }
                    .help("Hide the icons on the desktop (restarts Finder)")
                }
                if l.available && l.isOn { logoModes.transition(appear) }
                if let msg = c.permissionMessage { note(msg, .orange).transition(appear) }
                if p.lidAwake {
                    note("Lid-closed awake is ON. Don't put the Mac in a bag while it's on: it will stay hot. It turns off when you untick it or quit.", .orange)
                        .transition(appear)
                }
                if let e = p.lastError { note(e, .red).transition(appear) }
            }
            .animation(anim, value: [l.available && l.isOn, c.permissionMessage != nil, p.lidAwake, p.lastError != nil])

            if menuBarOpen {
            section("Menu bar") {
                LazyVGrid(columns: five, spacing: 6) {
                    Tile(icon: "cpu", title: "CPU", subtitle: "", isOn: m.showCPU, inline: true) { m.showCPU.toggle() }
                    Tile(icon: "square.stack.3d.up", title: "GPU", subtitle: "", isOn: m.showGPU, inline: true) { m.showGPU.toggle() }
                    Tile(icon: "fan", title: "Fan", subtitle: "", isOn: m.showFan, inline: true) { m.showFan.toggle() }
                    Tile(icon: "thermometer.medium", title: "CPU°", subtitle: "", isOn: m.showCPUTemp, inline: true) { m.showCPUTemp.toggle() }
                    Tile(icon: "thermometer.high", title: "GPU°", subtitle: "", isOn: m.showGPUTemp, inline: true) { m.showGPUTemp.toggle() }
                    Tile(icon: "internaldrive", title: "Disk", subtitle: "", isOn: m.showDisk, inline: true) { m.showDisk.toggle() }
                }
            }
            .transition(appear)
            }

            // Footer: the set-once menu bar choices fold away; Quit is a quiet capsule, not a full-width button.
            HStack {
                Button(action: { menuBarOpen.toggle() }) {
                    HStack(spacing: 4) {
                        Text("MENU BAR OPTIONS").font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(menuBarOpen ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose what appears in the menu bar")
                Spacer()
                Button(action: onQuit) {
                    Text("Quit").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Theme.subtleFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
                .help("Quit SiliconMonitor (⌘Q)")
            }
        }
        .animation(anim, value: menuBarOpen)
        .animation(anim, value: th.limited) // on the whole stack, so the section fades in while the card grows
        .padding(14)
        .frame(width: CardStyle.width)
    }

    /// Shared by everything that appears or disappears; instant when Reduce motion is on.
    private var anim: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.2)
    }

    private var appear: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
    }

    private func shown(_ on: Bool) -> String { on ? "Shown" : "Hidden" }

    /// Two-fan MacBook Pros: fan 0 is the left fan, fan 1 the right.
    private func fanName(_ i: Int) -> String {
        m.fans.count == 2 ? (i == 0 ? "Left" : "Right") : "Fan \(i + 1)"
    }

    @ViewBuilder private var fansSection: some View {
        if !m.smcAvailable {
            note("SMC unavailable: temperatures and fans can't be read.", .secondary)
        } else if m.fans.isEmpty {
            note("No fans reported.", .secondary)
        } else {
            HStack(spacing: 14) {
                Image(systemName: "fan").font(.caption).foregroundStyle(.secondary)
                ForEach(m.fans) { f in
                    Text("\(fanName(f.id))  ").font(.caption).foregroundStyle(.secondary)
                        + Text(String(format: "%.0f rpm", f.rpm)).font(.callout).monospacedDigit()
                }
                Spacer()
            }
        }
    }

    // MARK: Throttle detector

    /// "Super 4.6 · Performance 2.6 GHz": the busiest cluster of each core tier.
    private var clockSummary: String {
        var tiers: [(name: String, mhz: Double, active: Double)] = []
        for (letter, name) in [("P", m.topTierName), ("M", m.lowTierName), ("E", m.lowTierName)] {
            if let c = th.clocks.filter({ $0.name.hasPrefix(letter) }).max(by: { $0.active < $1.active }) {
                tiers.append((name, c.mhz, c.active))
            }
        }
        return tiers.map { String(format: "%@ %.1f", $0.name, $0.mhz / 1000) }.joined(separator: " · ") + (tiers.isEmpty ? "" : " GHz")
    }

    private func eventLine(_ e: ThrottleEvent, live: Bool) -> String {
        let secs = Int((e.end ?? Date()).timeIntervalSince(e.start))
        let length = secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs)s"
        let time = e.start.formatted(date: .omitted, time: .shortened)
        var line = "\(live ? "Now" : time) · \(length) · \(e.causes.joined(separator: ", "))"
        let temps = [e.peakCPUTemp.map { String(format: "CPU %.0f°", $0) }, e.peakGPUTemp.map { String(format: "GPU %.0f°", $0) },
                     e.peakPower.map { String(format: "%.0f W", $0) }].compactMap { $0 }.filter { !$0.hasPrefix("CPU 0") && !$0.hasPrefix("GPU 0") && $0 != "0 W" }
        if !temps.isEmpty { line += " · peak " + temps.joined(separator: ", ") }
        return line
    }

    /// A slim strip at the top while macOS is limiting performance, with the cause; it goes away when throttling ends.
    @ViewBuilder private var throttleBanner: some View {
        if th.available && th.limited {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                Text(th.causes.first.map { $0 + (th.causes.count > 1 ? " +\(th.causes.count - 1)" : "") } ?? "Performance limited")
                    .font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(Color.orange.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
            .help(th.causes.joined(separator: ", "))
            .transition(appear)
        }
    }

    /// Top-tier clock speed over the last minute as a share of its maximum, next to the Power graph. Stretches where
    /// macOS was limiting performance are shaded orange. Hover for the recent events; right-click to clear them.
    @ViewBuilder private var clocksSection: some View {
        if th.available && !th.clockHistory.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Clocks").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if th.limited {
                        Text("Limited").font(.callout).foregroundStyle(.orange).lineLimit(1)
                    } else if let c = th.topTierClock {
                        Text(String(format: "%.1f GHz", c.mhz / 1000)).monospacedDigit().lineLimit(1)
                    }
                }
                HistoryGraph(values: th.clockHistory, capacity: Monitor.maxHistory, lastSample: m.lastSample,
                             color: .purple, flags: th.limitedHistory)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .help(clocksTooltip)
            .contextMenu {
                Button("Clear throttle history") { th.clearHistory() }.disabled(th.events.isEmpty && th.current == nil)
            }
        }
    }

    private var clocksTooltip: String {
        var lines = ["Clock speed of the busiest \(m.topTierName) cluster, as a share of its maximum. Orange means macOS was limiting performance."]
        if !clockSummary.isEmpty { lines.append(clockSummary + ".") }
        if let now = th.current { lines.append("Now: " + eventLine(now, live: true)) }
        let past = th.events.prefix(5)
        if past.isEmpty && th.current == nil {
            lines.append("No throttling recorded yet.")
        } else if !past.isEmpty {
            lines.append("Recent:")
            lines.append(contentsOf: past.map { eventLine($0, live: false) })
        }
        return lines.joined(separator: "\n")
    }

    private static let gib = 1_073_741_824.0   // Activity Monitor counts memory in GiB

    /// One full-width bar with the icon and value written inside it, so both rows are the same length
    /// and no space is wasted beside the bar. The fill is translucent so the text reads on top of it.
    private func barRow(icon: String, fraction: Double, color: Color, leading: Text? = nil, value: Text) -> some View {
        HStack(spacing: 7) {
            leading?.lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            value.lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .background(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().fill(color.opacity(0.45)).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .background(Theme.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// Startup volume: bar = space used (orange above 90%), value = space remaining. Read/write speed in the tooltip.
    @ViewBuilder private var diskSection: some View {
        if m.diskTotal > 0 {
            let used = Double(m.diskTotal - m.diskFree) / Double(m.diskTotal)
            barRow(icon: "internaldrive", fraction: used,
                   color: used > 0.9 ? .orange : .blue,
                   value: Text(String(format: "%.0f / %.0f GB free", Double(m.diskFree) / 1e9, Double(m.diskTotal) / 1e9)).font(.callout).monospacedDigit())
                .help(String(format: "%.0f GB free of %.0f GB. ", Double(m.diskFree) / 1e9, Double(m.diskTotal) / 1e9)
                      + "Reading " + Monitor.rate(m.diskRead) + ", writing " + Monitor.rate(m.diskWrite) + ".")
        }
    }

    /// Memory: bar = memory in use, coloured by the kernel's pressure level (green, yellow, red).
    @ViewBuilder private var memorySection: some View {
        if m.memTotal > 0 {
            let (label, color): (String, Color) = m.memPressure >= 4 ? ("Critical", .red) : m.memPressure >= 2 ? ("Warning", .yellow) : ("Normal", .green)
            let swapping = m.swapUsed >= 50_000_000   // only when macOS is actually swapping
            barRow(icon: "memorychip", fraction: Double(m.memUsed) / Double(m.memTotal), color: color,
                   value: Text(String(format: "%.1f / %.0f GB", Double(m.memUsed) / Self.gib, Double(m.memTotal) / Self.gib))
                            .font(.callout).monospacedDigit()
                        + Text(swapping ? String(format: " +%.1f swap", Double(m.swapUsed) / Self.gib) : "")
                            .font(.caption).foregroundStyle(.secondary))
            .help(String(format: "Memory pressure: %@. Swap used: %.1f GB.", label, Double(m.swapUsed) / Self.gib))
        }
    }

    /// Network speed on the left, whole-Mac power draw on the right.
    @ViewBuilder private var networkSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
            Text(Image(systemName: "arrow.down")).font(.caption).foregroundStyle(.secondary)
                + Text(" " + Monitor.rate(m.netDown)).font(.callout).monospacedDigit()
            Text(Image(systemName: "arrow.up")).font(.caption).foregroundStyle(.secondary)
                + Text(" " + Monitor.rate(m.netUp)).font(.callout).monospacedDigit()
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .help("Network speed")
    }

    /// Power the whole Mac draws, as a 1-minute graph. The graph's top is the highest reading in the window
    /// (at least 20 W, rounded up to 10), so quiet and heavy loads both fill the plot sensibly.
    @ViewBuilder private var powerSection: some View {
        if let w = m.systemPower {
            let top = max(20, ((m.powerHistory.max() ?? 0) * 1.3 / 10).rounded(.up) * 10)   // headroom keeps the scale label clear of the line
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Power").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(String(format: "%.1f W", w)).monospacedDigit()
                }
                HistoryGraph(values: m.powerHistory.map { $0 / top * 100 }, capacity: Monitor.maxHistory, lastSample: m.lastSample, color: .orange)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
                    .overlay(alignment: .topTrailing) {
                        Text(String(format: "%.0f W", top)).font(.system(size: 9)).foregroundStyle(.secondary).padding(.trailing, 10).padding(.top, 2)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            }
            .frame(maxWidth: .infinity)
            .help("Power the whole Mac is drawing right now" + (m.adapterPower.map { String(format: ". Charger input: %.1f W", $0) } ?? ". Running on battery."))
        }
    }

    /// Battery as a bar like RAM and Storage: the fill is the charge level (orange at 20% or less, red at 10% or less),
    /// "Health · cycles" sit at the left inside it, and the charge status at the right.
    @ViewBuilder private var batterySection: some View {
        if m.batteryHealth != nil || m.cycleCount != nil || m.batteryPercent != nil {
            let pct = Double(m.batteryPercent ?? 0)
            let color: Color = pct <= 10 ? .red : pct <= 20 ? .orange : .green
            barRow(icon: m.batteryCharging ? "battery.100percent.bolt" : "battery.100", fraction: pct <= 20 ? pct / 100 : 0, color: color,   // a fill only when it matters
                   leading: Text(batteryInfo).font(.caption).foregroundStyle(Color.primary.opacity(0.75)),
                   value: Text(chargeStatus ?? "").font(.callout).monospacedDigit())
                .help(chargeTooltip)
        }
    }

    /// "Health 100%  ·  3 cycles"
    private var batteryInfo: String {
        var info: [String] = []
        if let h = m.batteryHealth { info.append(String(format: "Health %.0f%%", h)) }
        if let c = m.cycleCount { info.append("\(c) cycles") }
        return info.joined(separator: "  ·  ")
    }

    /// "62%  ·  1h 12m to full", "100%  ·  Plugged in", "40%  ·  3h 5m left".
    private var chargeStatus: String? {
        guard let pct = m.batteryPercent else { return nil }
        func hm(_ min: Int) -> String { min >= 60 ? "\(min / 60)h \(min % 60)m" : "\(min)m" }
        let detail: String
        if m.batteryCharging { detail = m.batteryMinutes.map { hm($0) + " to full" } ?? "Charging" }
        else if m.batteryPlugged { detail = (pct >= 99 || m.batteryFull) ? "Plugged in" : "Charge paused" }
        else { detail = m.batteryMinutes.map { hm($0) + " left" } ?? "On battery" }
        return "\(pct)%  ·  \(detail)"
    }

    private var chargeTooltip: String {
        var parts = ["Health: full-charge capacity compared with the battery's design capacity."]
        if m.batteryPlugged {
            parts.append(m.chargerWatts.map { "Charger: \($0) W." } ?? "Charger connected.")
            if let w = m.adapterPower { parts.append(String(format: "Input now: %.1f W.", w)) }
        } else { parts.append("Running on battery.") }
        return parts.joined(separator: " ")
    }

    /// Auto / manual switch for the fans, with a speed slider when manual and a one-tap Max.
    private var fanControlRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fanPill(icon: "fan", title: f.busy ? "Waiting…" : (f.manual ? "Manual" : "Auto"), on: f.manual && !f.isMax) {
                    f.setManual(!f.manual)
                }
                .help("The first time, this installs a small background helper (one admin password). Fans return to automatic when you quit.")
                fanPill(icon: "wind", title: "Max", on: f.isMax) {
                    f.isMax ? f.setManual(false) : f.setMax()
                }
                .help("Full speed on both fans. Tap again to go back to automatic.")
                if f.manual {
                    Slider(value: $f.percent, in: 0...100).frame(minWidth: 50).transition(.opacity)
                    Text(targetLabel).font(.caption).monospacedDigit().lineLimit(1).fixedSize().transition(.opacity)
                } else {
                    Spacer(minLength: 0)
                    Text(m.fans.isEmpty ? "Fans follow macOS" : m.fans.map { String(format: "%.0f", $0.rpm) }.joined(separator: " · ") + " rpm")
                        .font(.callout).monospacedDigit().lineLimit(1).transition(.opacity)
                        .help("Fan speeds. Fans follow macOS.")
                }
            }
            if let msg = f.message { note(msg, .orange).transition(appear) }
        }
        .animation(anim, value: f.manual)
        .animation(anim, value: f.message)
    }

    private func fanPill(icon: String, title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .fixedSize()   // never shrink or wrap: the slider gives way instead
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(Capsule(style: .continuous).fill(on ? Color.accentColor : Theme.subtleFill))
            .overlay(Capsule(style: .continuous).strokeBorder(on ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
        .disabled(f.busy || !m.smcAvailable)
    }

    /// Logo effects: Auto follows the screen, the rest are animations or a fixed level.
    private var logoModes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(LogoControl.Mode.allCases) { mode in
                    modePill(mode.title, on: l.mode == mode) { l.setMode(mode) }
                        .help(mode == .music ? "Flash the logo to the beat of whatever the Mac is playing. Asks for audio capture permission the first time." : "")
                }
            }
            if let note = l.musicNote {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .transition(appear)
            }
            if l.mode == .dim {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { l.dim }, set: { l.setDim($0) }), in: 0.1...1)
                    Text("\(Int((l.dim * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                .transition(appear)
            }
        }
        .padding(.top, 2)
        .animation(anim, value: l.mode == .dim)
        .animation(anim, value: l.musicNote)
    }

    private func modePill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(Capsule(style: .continuous).fill(on ? Color.accentColor : Theme.subtleFill))
                .overlay(Capsule(style: .continuous).strokeBorder(on ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    /// Target speed of the first fan, for the slider label.
    private var targetLabel: String {
        guard let fan = m.fans.first else { return "\(Int(f.percent))%" }
        return String(format: "%.0f rpm", fan.min + f.percent / 100 * (fan.max - fan.min))
    }

    private func section<Body: View>(_ title: String, @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).tracking(0.4)
            body()
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    // One vertical bar per core; lower-tier cores first, then the top tier in a second colour.
    private var coreBars: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(m.coreLoads.enumerated()), id: \.offset) { i, load in
                    let isTop = i >= m.lowTierCount
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.secondary.opacity(0.2))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isTop ? Color.orange : Color.blue)
                            .frame(height: max(2, 26 * min(load, 100) / 100))
                    }
                    .frame(height: 26)
                    .help(String(format: "Core %d (%@): %.0f%%", i + 1, isTop ? m.topTierName : m.lowTierName, load))
                }
            }
            HStack(spacing: 10) {
                legend(.blue, "\(m.lowTierName) ×\(m.lowTierCount)")
                legend(.orange, "\(m.topTierName) ×\(m.topTierCount)")
            }
            .help("One bar per core, showing its load. \(m.lowTierName) cores are blue, \(m.topTierName) cores are orange.")
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Graphs

    private func graph(_ name: String, value: Double, temp: Double?, history: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let t = temp { Text(String(format: "%.0f°C", t)).monospacedDigit().foregroundStyle(Color.primary.opacity(0.75)) }
                Text(String(format: "%.0f%%", value)).monospacedDigit()
            }
            HistoryGraph(values: history, capacity: Monitor.maxHistory, lastSample: m.lastSample, color: color)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

/// Rolling line-and-area graph, 0-100%, built from Core Animation layers.
///
/// The line only changes once per sample, so once per sample it is drawn (line and gradient fill) into a
/// single bitmap on the CPU. Between samples that finished image is scrolled left by one sample width with a
/// linear animation the render server performs: no per-frame work in the app, and for the GPU just moving a
/// flat texture. (A shape layer with a gradient mask, scrolled, made the GPU re-render it every frame: ~20%
/// GPU utilization.) The graph is drawn one sample interval in the past, so its right edge is always an
/// interpolation between two real samples. Equal padding on all sides, faint gridlines at 0/50/100%.
final class GraphNSView: NSView {
    private let grid = CAShapeLayer()
    private let clip = CALayer()      // the plot area; clips the scrolling content
    private let scroll = CALayer()    // animated sideways
    private let content = CALayer()   // the pre-drawn line + fill image

    private let inset: CGFloat = 8
    private var color = NSColor.systemBlue
    private var values: [Double] = []
    private var flags: [Bool] = []
    private var capacity = 2
    private var lastSample = Date()
    private var builtKey: [Double] = []   // count, sample time, capacity, width, height, scale of the last build

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grid.fillColor = nil
        grid.lineWidth = 0.5
        clip.masksToBounds = true
        scroll.addSublayer(content)
        clip.addSublayer(scroll)
        layer?.addSublayer(grid)
        layer?.addSublayer(clip)
        refreshColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
        builtKey = []          // the image bakes the colours in, so redraw it
        rebuildIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        builtKey = []
        rebuildIfNeeded()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            grid.strokeColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        }
    }

    func update(values: [Double], capacity: Int, lastSample: Date, color: NSColor, flags: [Bool] = []) {
        let colorChanged = color != self.color
        self.values = values; self.capacity = capacity; self.lastSample = lastSample; self.color = color; self.flags = flags
        if colorChanged { builtKey = [] }
        rebuildIfNeeded()
    }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    private func rebuildIfNeeded() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = [Double(values.count), lastSample.timeIntervalSinceReferenceDate, Double(capacity),
                   Double(bounds.width), Double(bounds.height), Double(scale)]
        guard key != builtKey, bounds.width > 2 * inset, bounds.height > 2 * inset else { return }
        builtKey = key

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let w = bounds.width - 2 * inset, h = bounds.height - 2 * inset
        grid.frame = bounds
        let g = CGMutablePath()
        for f in [0.0, 0.5, 1.0] {
            g.move(to: CGPoint(x: inset, y: inset + h * f))
            g.addLine(to: CGPoint(x: inset + w, y: inset + h * f))
        }
        grid.path = g

        clip.frame = CGRect(x: inset, y: inset, width: w, height: h)
        scroll.removeAllAnimations()
        scroll.frame = CGRect(x: 0, y: 0, width: w, height: h)
        let dx = w / CGFloat(max(capacity - 1, 1))
        let pad = 2 * dx
        content.frame = CGRect(x: -pad, y: 0, width: w + 2 * pad, height: h)
        content.contentsScale = scale

        let pts = values.suffix(capacity + 2)
        guard pts.count >= 2 else { content.contents = nil; return }
        let n = pts.count
        // The newest sample sits at the right edge; the graph steps left by one sample each second (no scrolling animation).
        let points: [CGPoint] = pts.enumerated().map { i, v in
            CGPoint(x: w - CGFloat(n - 1 - i) * dx, y: h * CGFloat(min(max(v, 0), 100) / 100))
        }
        // Smooth curve through segment midpoints: rounded, and never overshoots the data range.
        let line = CGMutablePath()
        line.move(to: points[0])
        for i in 1..<(n - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            line.addQuadCurve(to: mid, control: points[i])
        }
        line.addLine(to: points[n - 1])
        let area = CGMutablePath()
        area.addPath(line)
        area.addLine(to: CGPoint(x: points[n - 1].x, y: 0))
        area.addLine(to: CGPoint(x: points[0].x, y: 0))
        area.closeSubpath()

        // Shaded bands for the intervals flagged as limited (the flag of a sample covers the step that ends at it).
        let flagged = Array(flags.suffix(n))
        var bands: [CGRect] = []
        if flagged.count == n {
            for i in 1..<n where flagged[i] {
                bands.append(CGRect(x: points[i - 1].x, y: 0, width: points[i].x - points[i - 1].x, height: h))
            }
        }
        content.contents = renderImage(line: line, area: area, bands: bands, size: content.bounds.size, pad: pad, scale: scale)
    }

    /// Draws the gradient fill and the line into one bitmap (CPU), covering the plot plus `pad` on each side.
    private func renderImage(line: CGPath, area: CGPath, bands: [CGRect], size: CGSize, pad: CGFloat, scale: CGFloat) -> CGImage? {
        let pxW = Int(ceil(size.width * scale)), pxH = Int(ceil(size.height * scale))
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: pad, y: 0)    // paths are in plot coordinates; the image starts `pad` to the left

        if !bands.isEmpty {
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.28).cgColor)
            ctx.fill(bands)
        }
        var line_c = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { line_c = color.cgColor }
        let top = line_c.copy(alpha: 0.30) ?? line_c, bottom = line_c.copy(alpha: 0.02) ?? line_c
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(area)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
            ctx.restoreGState()
        }
        ctx.setStrokeColor(line_c)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(line)
        ctx.strokePath()
        return ctx.makeImage()
    }
}

struct HistoryGraph: NSViewRepresentable {
    let values: [Double]
    let capacity: Int
    let lastSample: Date
    let color: Color
    var flags: [Bool] = []   // optional: one per value; true shades that stretch of the graph orange

    func makeNSView(context: Context) -> GraphNSView { GraphNSView() }

    func updateNSView(_ view: GraphNSView, context: Context) {
        view.update(values: values, capacity: capacity, lastSample: lastSample, color: NSColor(color), flags: flags)
    }
}

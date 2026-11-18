import AppKit
import IOKit.pwr_mgt

/// "Keep screen on" (power assertion) and "Don't sleep when lid is closed" (pmset disablesleep).
@MainActor
final class PowerMode: ObservableObject {
    @Published var keepScreenOn = false
    @Published var lidAwake = false      // mirrors the system's SleepDisabled flag
    @Published var busy = false          // waiting on the admin password prompt
    @Published var lastError: String?

    private var assertionID: IOPMAssertionID = 0

    init() {
        // Reflect reality: SleepDisabled may still be on from an earlier session that didn't get to revert it.
        lidAwake = Self.readSleepDisabled()
    }

    // MARK: Keep screen on

    func setKeepScreenOn(_ on: Bool) {
        if on {
            guard assertionID == 0 else { return }
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "SiliconMonitor: keep screen on" as CFString, &id)
            if r == kIOReturnSuccess { assertionID = id; keepScreenOn = true }
        } else {
            if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
            keepScreenOn = false
        }
    }

    // MARK: Lid closed

    func setLidAwake(_ on: Bool) {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task {
            let ok = await Task.detached { Self.runPrivileged("/usr/bin/pmset -a disablesleep \(on ? 1 : 0)") }.value
            lidAwake = Self.readSleepDisabled()
            if !ok { lastError = "Admin approval was cancelled or failed." }
            busy = false
        }
    }

    /// Called before quitting so the Mac isn't left unable to sleep.
    func restoreBeforeQuit() async {
        setKeepScreenOn(false)
        guard lidAwake else { return }
        _ = await Task.detached { Self.runPrivileged("/usr/bin/pmset -a disablesleep 0") }.value
        lidAwake = Self.readSleepDisabled()
    }

    // MARK: Helpers

    nonisolated static func runPrivileged(_ command: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    nonisolated static func readSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("SleepDisabled") }) else { return false }
        return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
    }
}

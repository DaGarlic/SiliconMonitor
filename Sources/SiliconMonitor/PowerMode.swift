import AppKit
import IOKit.pwr_mgt

/// "Keep screen on" (power assertion) and "Don't sleep when lid is closed" (pmset disablesleep).
@MainActor
final class PowerMode: ObservableObject {
    @Published var keepScreenOn = false
    @Published var lidAwake = false      // mirrors the system's SleepDisabled flag
    @Published var busy = false          // waiting on the helper (or the one-time admin password prompt)
    @Published var lastError: String?

    private var assertionID: IOPMAssertionID = 0
    private var helperFD: Int32 = -1
    private var heartbeat: Timer?

    init() {
        // Reflect reality: SleepDisabled may still be on from an earlier session that didn't get to revert it.
        Task { await refreshLid() }
    }

    /// Re-reads the system flag off the main thread (pmset can take a moment).
    private func refreshLid() async {
        lidAwake = await Task.detached { Self.readSleepDisabled() }.value
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
            let ok = await applyLid(on)
            await refreshLid()
            if !ok { lastError = "Couldn't reach the helper (admin approval cancelled or failed)." }
            busy = false
        }
    }

    /// Asks the root helper (the one fan control installs) to change `pmset disablesleep`. The password is only
    /// needed the first time, when the helper is installed. While the lid stays awake this app keeps a connection
    /// open: if the app quits or crashes, the helper lets the Mac sleep again on its own.
    private func applyLid(_ on: Bool) async -> Bool {
        var r = await Task.detached { FanController.openConnection() }.value
        if r.status == .unreachable || r.status == .wrongVersion {
            guard await Task.detached(operation: { FanController.installHelper() }).value else { return false }
            for _ in 0..<50 {                                   // up to 5 s for the new daemon to start listening
                r = await Task.detached { FanController.openConnection() }.value
                if r.status == .ok || r.status == .busy { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard r.status == .ok else { return false }
        if on {
            closeLink()
            helperFD = r.fd
            sendToHelper("LID 1")
            heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sendToHelper("PING"); self?.checkHelper() }
            }
        } else {
            closeLink()
            let bytes = Array("LID 0\n".utf8)
            _ = write(r.fd, bytes, bytes.count)
            close(r.fd)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)         // let pmset finish before we read the flag back
        return true
    }

    private func sendToHelper(_ line: String) {
        guard helperFD >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        if write(helperFD, bytes, bytes.count) < 0 {            // helper went away: it has let the Mac sleep again
            closeLink()
            Task { await refreshLid() }
        }
    }

    /// The helper can end the lid hold by itself (it got too hot, or the helper stopped): pick that up.
    private func checkHelper() {
        guard helperFD >= 0 else { return }
        var p = pollfd(fd: helperFD, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(helperFD, &buf, buf.count)
        if n <= 0 { closeLink(); Task { await refreshLid() }; return }
        if String(decoding: buf.prefix(n), as: UTF8.self).contains("LIDOFF") {
            closeLink()
            lidAwake = false
            lastError = "The Mac got hot, so it can sleep again with the lid closed."
        }
    }

    private func closeLink() {
        heartbeat?.invalidate(); heartbeat = nil
        if helperFD >= 0 { close(helperFD); helperFD = -1 }
    }

    /// Called before quitting so the Mac isn't left unable to sleep.
    func restoreBeforeQuit() async {
        setKeepScreenOn(false)
        if helperFD >= 0 {
            sendToHelper("LID 0")
            closeLink()
        } else if lidAwake {
            // Stale flag from an earlier session: clear it if the helper is already there (never prompt while quitting).
            let r = await Task.detached { FanController.openConnection() }.value
            if r.status == .ok {
                let bytes = Array("LID 0\n".utf8)
                _ = write(r.fd, bytes, bytes.count)
                try? await Task.sleep(nanoseconds: 300_000_000)
                close(r.fd)
            }
        }
        await refreshLid()
    }

    // MARK: Helpers

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

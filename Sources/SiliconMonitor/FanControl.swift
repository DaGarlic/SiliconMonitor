import AppKit
import Darwin

/// App side of fan control. Talks to a root daemon (installed once, with one admin password) that does the
/// SMC writes. Manual mode lasts only while this app is connected: disconnecting, quitting, crashing or going
/// silent all put the fans back on automatic.
@MainActor
final class FanController: ObservableObject {
    nonisolated static let label = "local.siliconmonitor.fanhelper"
    nonisolated static let socketPath = "/var/run/local.siliconmonitor.fan.sock"
    nonisolated static let installedPath = "/Library/PrivilegedHelperTools/local.siliconmonitor.fanhelper"

    @Published var manual = false
    @Published var busy = false
    @Published var message: String?
    /// 0-100: where between each fan's minimum and maximum speed the target sits. 100 = full speed.
    @Published var percent: Double {
        didSet {
            UserDefaults.standard.set(percent, forKey: "fanPercent")
            if manual { scheduleSend() }
        }
    }

    var isMax: Bool { manual && percent >= 100 }

    enum Connection { case ok, unreachable, busy, wrongVersion }

    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var heartbeat: Timer?
    private var pendingSend: Task<Void, Never>?

    init() {
        percent = UserDefaults.standard.object(forKey: "fanPercent") as? Double ?? 40
    }

    func setManual(_ on: Bool) { on ? enable() : disable() }

    /// Full speed on every fan. Switches to manual first if needed.
    func setMax() {
        percent = 100
        if !manual { enable() }
    }

    // MARK: Enable / disable

    private func enable() {
        guard !busy, !manual else { return }
        busy = true
        message = nil
        Task {
            var result = connect()
            if result == .unreachable || result == .wrongVersion {
                // Not installed yet (or an old copy): install once. This is the only password prompt.
                let installed = await Task.detached { Self.installHelper() }.value
                guard installed else {
                    message = "Admin approval was cancelled or failed."
                    busy = false
                    return
                }
                for _ in 0..<50 {                              // give the new daemon up to 5 s to start listening
                    result = connect()
                    if result == .ok || result == .busy { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            switch result {
            case .ok:
                manual = true
                sendTarget()
                heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sendTarget() }   // also the heartbeat
                }
            case .busy:
                message = "The fan helper is still finishing a previous session. Try again in a few seconds."
            case .unreachable, .wrongVersion:
                message = "Couldn't reach the fan helper."
            }
            busy = false
        }
    }

    /// Back to automatic: tell the helper, then disconnect (it also reverts on its own when we do).
    private func disable() {
        if fd >= 0 { send("AUTO") }
        closeConnection()
        manual = false
    }

    /// Called when the app quits.
    func shutdown() { disable() }

    // MARK: Talking to the helper

    private func scheduleSend() {
        pendingSend?.cancel()
        pendingSend = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)   // debounce slider drags
            guard !Task.isCancelled else { return }
            sendTarget()
        }
    }

    private func sendTarget() { send("SET \(Int(percent.rounded()))") }

    private func send(_ line: String) {
        guard fd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        if write(fd, bytes, bytes.count) < 0 { helperGone() }
    }

    private func connect() -> Connection {
        let r = Self.openConnection()
        guard r.status == .ok else { return r.status }
        fd = r.fd
        let s = r.fd

        // Listen for the helper's own messages (it can revert on its own, e.g. when too hot).
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readFromHelper() } }
        src.resume()
        reader = src
        return .ok
    }

    private func readFromHelper() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        if n <= 0 { helperGone(); return }
        let text = String(decoding: buf.prefix(n), as: UTF8.self)
        if text.split(separator: "\n").contains(where: { $0.hasPrefix("AUTO") }) {
            let hot = text.contains("thermal")
            closeConnection()
            manual = false
            message = hot ? "The Mac got hot, so the fans went back to automatic." : "Fans are back on automatic."
        }
    }

    private func helperGone() {
        let wasManual = manual
        closeConnection()
        manual = false
        if wasManual { message = "The fan helper stopped, so the fans are back on automatic." }
    }

    private func closeConnection() {
        heartbeat?.invalidate(); heartbeat = nil
        pendingSend?.cancel(); pendingSend = nil
        reader?.cancel(); reader = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Opens a connection to the root helper and checks its protocol version. Shared with PowerMode (lid sleep).
    nonisolated static func openConnection() -> (fd: Int32, status: Connection) {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return (-1, .unreachable) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            socketPath.withCString { _ = strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        addr.sun_len = UInt8(len)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) } }
        guard r == 0 else { close(s); return (-1, .unreachable) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // The helper greets with its protocol version. No greeting means it is busy serving another client.
        var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 1500) > 0 else { close(s); return (-1, .busy) }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(s, &buf, buf.count)
        let hello = String(decoding: buf.prefix(max(n, 0)), as: UTF8.self)
        guard hello.hasPrefix("HELLO \(fanHelperVersion)") else { close(s); return (-1, n > 0 ? .wrongVersion : .unreachable) }
        return (s, .ok)
    }

    // MARK: Installing the helper

    /// Installs (or replaces) the root daemon: one admin-password prompt, once. The binary is copied to a
    /// root-owned location so nothing running as the user can alter it, then registered with launchd.
    nonisolated static func installHelper() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let plistPath = "/Library/LaunchDaemons/\(label).plist"
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
            + "<plist version=\"1.0\"><dict>"
            + "<key>Label</key><string>\(label)</string>"
            + "<key>ProgramArguments</key><array><string>\(installedPath)</string><string>--fan-helper</string>"
            + "<string>\(socketPath)</string><string>\(getuid())</string></array>"
            + "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>5</integer>"
            + "</dict></plist>"
        let script = """
        set -e
        /bin/mkdir -p /Library/PrivilegedHelperTools
        /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
        /bin/cp '\(exe)' '\(installedPath)'
        /usr/sbin/chown root:wheel '\(installedPath)'
        /bin/chmod 755 '\(installedPath)'
        /usr/bin/printf '%s' '\(plist)' > '\(plistPath)'
        /usr/sbin/chown root:wheel '\(plistPath)'
        /bin/chmod 644 '\(plistPath)'
        /bin/launchctl bootstrap system '\(plistPath)'
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The script travels as an argument, so no AppleScript string escaping is needed.
        p.arguments = ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges",
                       "-e", "end run", script]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

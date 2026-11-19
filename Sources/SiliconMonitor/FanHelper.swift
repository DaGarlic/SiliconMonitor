import Foundation
import CSMC

// The root half of fan control: a small launchd daemon, installed once (see FanController.installHelper).
//   /Library/PrivilegedHelperTools/local.siliconmonitor.fanhelper --fan-helper <socket path> <allowed uid>
//
// It listens on a Unix socket and serves one client at a time, but only the user it was installed for
// (checked with the peer's real uid, not just file permissions). Commands, one per line:
//   SET <0-100>  manual mode, target = min + percent * (max - min) for each fan
//   AUTO         hand the fans back to macOS
//   LID <0|1>    pmset disablesleep 0/1 (stay awake with the lid closed); reverted when that client goes away,
//                or after 6 s above 95 C (the client is told with "LIDOFF thermal")
//   PING         heartbeat
// It greets each client with "HELLO <version>" so the app can tell when the installed copy is out of date.
//
// Each client is served on its own thread; shared state and every SMC / pmset call go through `helperLock`.
// The silence timeout uses the uptime clock, which stands still while the Mac sleeps, so a sleep/wake cycle
// doesn't look like a dead client.
// Safety: the fans go back to automatic whenever the client that set them disconnects, goes silent for 10 s, the
// process is stopped, or the chip reaches 95 C (manual control is then refused until it cools to 85 C).

/// Bump when the protocol changes; the app reinstalls the helper if the versions differ.
let fanHelperVersion = 5

private let helperLock = NSRecursiveLock()
@discardableResult private func locked<T>(_ body: () -> T) -> T { helperLock.lock(); defer { helperLock.unlock() }; return body() }
private func uptimeSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

/// Exists while this helper has disablesleep switched on, so a crash or reboot can't leave it on for good.
private let lidMarker = "/var/db/local.siliconmonitor.lid-held"

nonisolated(unsafe) private var helperSocketPath = ""
nonisolated(unsafe) private var thermalBlocked = false   // set after a thermal revert; cleared once cooled

nonisolated(unsafe) private var lidHeld = 0   // clients currently holding "stay awake with the lid closed"

private func setLidSleepDisabled(_ on: Bool) {
    locked {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if on { FileManager.default.createFile(atPath: lidMarker, contents: nil) }
        else { try? FileManager.default.removeItem(atPath: lidMarker) }
    }
}

private func helperShutdown() -> Never {
    restoreAutomaticFans()   // no lock here: this runs in a signal handler
    if lidHeld > 0 { setLidSleepDisabled(false) }
    unlink(helperSocketPath)
    exit(0)
}

private func applyFanPercent(_ percent: Double) {
    let n = Int(readSMC("FNum") ?? 0)
    for i in 0..<n {
        let mn = readSMC("F\(i)Mn") ?? 2000
        let mx = readSMC("F\(i)Mx") ?? 6000
        let rpm = mn + min(max(percent, 0), 100) / 100 * (mx - mn)
        _ = smcWriteU8("F\(i)md", 1)
        _ = smcWriteFloat("F\(i)Tg", Float(rpm))
    }
}

private func hottestTemperature(keys: [String]) -> (name: String, value: Double) {
    var best = (name: "", value: 0.0)
    for k in keys { if let v = readSMC(k), v > 5, v < 130, v > best.value { best = (k, v) } }
    return best
}

private func temperatureKeys() -> [String] {
    var keys: [String] = []
    let count = Int(readSMC("#KEY") ?? 0)
    for i in 0..<count {
        let k = smc_key_at(UInt32(i))
        guard k != 0 else { continue }
        let name = fourCCString(k)
        if (name.hasPrefix("Tp") || name.hasPrefix("Tg")), let v = readSMC(name), v > 5, v < 130 { keys.append(name) }
    }
    return keys
}

/// Serves one connected client (on its own thread) until it disconnects, goes silent, or errors.
private func serve(client: Int32, tempKeys: [String]) {
    var tv = timeval(tv_sec: 2, tv_usec: 0)   // wake every 2 s for the heartbeat and thermal checks
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    func reply(_ s: String) { let d = Array((s + "\n").utf8); _ = write(client, d, d.count) }
    reply("HELLO \(fanHelperVersion)")

    let tooHot = 95.0, cooledTo = 85.0
    var hotReadings = 0   // consecutive hot samples; one stray SMC reading must not cancel manual fans
    var manualOn = false
    var lidOn = false
    var lastBeat = uptimeSeconds()
    var pending = ""
    var buf = [UInt8](repeating: 0, count: 256)

    func handle(_ line: String) {
        let parts = line.split(separator: " ")
        switch parts.first {
        case "SET":
            guard !locked({ thermalBlocked }) else { reply("AUTO thermal"); return }
            locked { applyFanPercent(Double(parts.dropFirst().first ?? "") ?? 0) }
            manualOn = true
        case "AUTO":
            locked { restoreAutomaticFans() }; manualOn = false
        case "LID":
            let want = parts.dropFirst().first == "1"
            locked {
                if want { if !lidOn { lidOn = true; lidHeld += 1 }; setLidSleepDisabled(true) }
                else { if lidOn { lidOn = false; lidHeld -= 1 }; if lidHeld == 0 { setLidSleepDisabled(false) } }
            }
        default:
            break   // PING and anything unknown just count as a heartbeat
        }
    }

    while true {
        let n = read(client, &buf, buf.count)
        if n == 0 { break }                                              // app closed the connection
        if n < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK { break }         // a real error; a timeout is fine
        } else {
            lastBeat = uptimeSeconds()
            pending += String(decoding: buf.prefix(n), as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                handle(String(pending[..<nl]))
                pending.removeSubrange(...nl)
            }
        }
        if uptimeSeconds() - lastBeat > 10 { break }             // app went silent

        let t = hottestTemperature(keys: tempKeys)
        hotReadings = t.value >= tooHot ? hotReadings + 1 : 0
        if manualOn && hotReadings >= 3 {   // about 6 s sustained
            locked { restoreAutomaticFans(); thermalBlocked = true }
            manualOn = false
            reply("AUTO thermal \(Int(t.value)) \(t.name)")
        } else if t.value < cooledTo {
            locked { thermalBlocked = false }
        }
        if lidOn && hotReadings >= 3 {   // too hot to stay awake with the lid closed (it may be in a bag): let it sleep
            lidOn = false
            locked { lidHeld -= 1; if lidHeld == 0 { setLidSleepDisabled(false) } }
            reply("LIDOFF thermal \(Int(t.value)) \(t.name)")
        }
    }
    if lidOn { locked { lidHeld -= 1; if lidHeld == 0 { setLidSleepDisabled(false) } } }   // the app went away: let the Mac sleep again
    if manualOn { locked { restoreAutomaticFans() } }   // whatever ended a manual session, the fans go back to macOS
}

func runFanHelper(socketPath: String, uid allowedUID: uid_t) -> Never {
    helperSocketPath = socketPath
    guard smc_open() == 0 else { exit(2) }
    for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig) { _ in helperShutdown() } }
    signal(SIGPIPE, SIG_IGN)
    restoreAutomaticFans()   // start clean, in case a previous run died while in manual mode
    if FileManager.default.fileExists(atPath: lidMarker) { setLidSleepDisabled(false) }   // a previous run died with the lid held

    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { exit(3) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        socketPath.withCString { _ = strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    addr.sun_len = UInt8(len)
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, len) } }
    guard bound == 0 else { exit(4) }
    chmod(socketPath, 0o666)   // anyone can connect; the peer's uid is checked below
    listen(server, 4)

    let tempKeys = temperatureKeys()
    while true {
        let client = accept(server, nil, nil)
        if client < 0 { continue }
        var euid: uid_t = 0, egid: gid_t = 0
        guard getpeereid(client, &euid, &egid) == 0, euid == allowedUID else { close(client); continue }
        Thread.detachNewThread {
            serve(client: client, tempKeys: tempKeys)
            close(client)
        }
    }
}

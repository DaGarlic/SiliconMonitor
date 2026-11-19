import Foundation
import IOKit
import CSMC

struct Fan: Identifiable {
    let id: Int
    var rpm: Double
    var min: Double
    var max: Double
}

// MARK: - SMC helpers

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

func fourCCString(_ v: UInt32) -> String {
    String(decoding: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], as: UTF8.self)
}

func readSMC(_ key: String) -> Double? {
    var buf = [UInt8](repeating: 0, count: 32)
    var size: UInt32 = 0, type: UInt32 = 0
    guard smc_read(fourCC(key), &buf, &size, &type) == 0 else { return nil }
    switch type {
    case fourCC("flt "):
        guard size == 4 else { return nil }
        let bits = UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24
        return Double(Float(bitPattern: bits))
    case fourCC("ui8 "): return Double(buf[0])
    case fourCC("ui16"): return Double(UInt16(buf[0]) << 8 | UInt16(buf[1]))
    case fourCC("ui32"): return Double(UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3]))
    case fourCC("sp78"): return Double(Int16(bitPattern: UInt16(buf[0]) << 8 | UInt16(buf[1]))) / 256
    default: return nil
    }
}

// MARK: - Monitor

@MainActor
final class Monitor: ObservableObject {
    @Published var cpu = 0.0
    @Published var gpu = 0.0
    @Published var cpuTemp: Double?
    @Published var gpuTemp: Double?
    @Published var fans: [Fan] = []
    @Published var smcAvailable = false
    // Disk: boot volume capacity, and read/write throughput (bytes per second) since the previous sample.
    @Published var diskRead = 0.0
    @Published var diskWrite = 0.0
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0
    // Battery: health is the current full-charge capacity relative to the design capacity (like System Settings).
    @Published var batteryHealth: Double?
    @Published var cycleCount: Int?
    @Published var batteryPercent: Int?
    @Published var batteryPlugged = false       // a charger is connected
    @Published var batteryCharging = false
    @Published var batteryFull = false          // macOS reports the battery as fully charged
    @Published var batteryAmps: Int = 0         // signed battery current in mA (positive while charging)
    @Published var batteryMinutes: Int?         // to full while charging, to empty on battery (nil when macOS doesn't know yet)
    @Published var chargerWatts: Int?           // the connected charger's rating
    // Memory: used = app + wired + compressed (as Activity Monitor counts it); pressure is the kernel's 1/2/4 level.
    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = 0
    @Published var swapUsed: UInt64 = 0
    @Published var memPressure = 1
    // Network (all Wi-Fi / Ethernet / cellular-style interfaces, bytes per second) and whole-Mac power draw.
    @Published var netDown = 0.0
    @Published var netUp = 0.0
    @Published var systemPower: Double?     // watts, SMC key PSTR (everything the Mac is drawing right now)
    @Published var adapterPower: Double?    // watts coming in from the charger, SMC key PDTR
    private var prevNet: (counters: [String: (rx: UInt32, tx: UInt32)], time: Date)?
    private var prevDisk: (read: UInt64, write: UInt64, time: Date)?
    private var lastCapacityCheck = Date.distantPast
    private var lastBatteryCheck = Date.distantPast

    private var timer: Timer?
    @Published var coreLoads: [Double] = []
    // Rolling 1-minute history, one sample per refresh tick (every `sampleInterval` seconds).
    static let sampleInterval: TimeInterval = 1
    static let maxHistory = Int(60 / sampleInterval)
    /// Called once at the end of every refresh (so observers don't react to each individual value).
    var onRefresh: (() -> Void)?
    @Published var lastSample = Date()   // when the newest history sample was taken (drives smooth scrolling)
    @Published var cpuHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var gpuRenderer = 0.0
    @Published var gpuTiler = 0.0
    // Core tiers (e.g. 10 Performance + 5 Super). Cores are ordered lowest tier first.
    let lowTierName = Monitor.sysctlString("hw.perflevel1.name") ?? "Efficiency"
    let lowTierCount = Monitor.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    let topTierName = Monitor.sysctlString("hw.perflevel0.name") ?? "Performance"
    let topTierCount = Monitor.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
    var gpuCoreCount: Int { Monitor.gpuCores }
    private var prevCores: [[UInt64]]?
    private var cpuTempKeys: [String] = []
    private var gpuTempKeys: [String] = []

    // Which readings appear in the menu bar. Persisted in UserDefaults.
    @Published var showCPU: Bool { didSet { UserDefaults.standard.set(showCPU, forKey: "showCPU") } }
    @Published var showGPU: Bool { didSet { UserDefaults.standard.set(showGPU, forKey: "showGPU") } }
    @Published var showCPUTemp: Bool { didSet { UserDefaults.standard.set(showCPUTemp, forKey: "showCPUTemp") } }
    @Published var showGPUTemp: Bool { didSet { UserDefaults.standard.set(showGPUTemp, forKey: "showGPUTemp") } }
    @Published var showFan: Bool { didSet { UserDefaults.standard.set(showFan, forKey: "showFan") } }
    @Published var showDisk: Bool { didSet { UserDefaults.standard.set(showDisk, forKey: "showDisk") } }

    // Left-pads with spaces; the menu bar image uses a monospaced font, so every character is the same width.
    private func pad(_ v: Double?, width: Int) -> String {
        let s = v.map { String(format: "%.0f", $0) } ?? "-"
        return String(repeating: " ", count: max(0, width - s.count)) + s
    }

    /// One stacked readout in the menu bar: a tiny label over the value. `sample` is the widest value it can show,
    /// so every cell keeps a fixed width and the menu bar never jitters.
    struct MenuCell: Equatable {
        let label: String
        let value: String
        let sample: String
    }

    var menuCells: [MenuCell] {
        func num(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "–" }
        var cells: [MenuCell] = []
        if showCPU { cells.append(MenuCell(label: "CPU", value: num(cpu) + "%", sample: "100%")) }
        if showGPU { cells.append(MenuCell(label: "GPU", value: num(gpu) + "%", sample: "100%")) }
        if showCPUTemp { cells.append(MenuCell(label: "CPU°", value: num(cpuTemp) + "°", sample: "100°")) }
        if showGPUTemp { cells.append(MenuCell(label: "GPU°", value: num(gpuTemp) + "°", sample: "100°")) }
        if showFan { cells.append(MenuCell(label: "FAN", value: num(fans.first?.rpm), sample: "9999")) }
        if showDisk { cells.append(MenuCell(label: "DISK", value: num(Double(diskFree) / 1e9) + "G", sample: "999G")) }
        return cells
    }

    /// Plain-text form of the readout (used to notice when it changed).
    var menuTitle: String { menuCells.map { "\($0.label) \($0.value)" }.joined(separator: "  ") }

    init() {
        let d = UserDefaults.standard
        func flag(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
        showCPU = flag("showCPU", true)
        showGPU = flag("showGPU", true)
        showCPUTemp = flag("showCPUTemp", false)
        showGPUTemp = flag("showGPUTemp", false)
        showFan = flag("showFan", true)
        showDisk = flag("showDisk", false)
        smcAvailable = smc_open() == 0
        if smcAvailable { discoverKeys() }
        refresh()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(record: true) }
        }
    }

    private func discoverKeys() {
        let count = Int(readSMC("#KEY") ?? 0)
        for i in 0..<count {
            let k = smc_key_at(UInt32(i))
            guard k != 0 else { continue }
            let name = fourCCString(k)
            // Apple Silicon: Tp* = CPU cluster temps, Tg* = GPU temps (only keep those that read as sane temperatures)
            guard name.hasPrefix("Tp") || name.hasPrefix("Tg"), let v = readSMC(name), v > 5, v < 130 else { continue }
            if name.hasPrefix("Tp") { cpuTempKeys.append(name) } else { gpuTempKeys.append(name) }
        }
    }

    func refresh(record: Bool = false) {
        defer { onRefresh?() }
        let c = Self.cpuLoad(prev: &prevCores)
        cpu = c.overall
        coreLoads = c.cores
        let g = Self.gpuLoad()
        gpu = g.device; gpuRenderer = g.renderer; gpuTiler = g.tiler
        updateDisk()
        updateMemory()
        updateNetwork()
        if Date().timeIntervalSince(lastBatteryCheck) > 2 { lastBatteryCheck = Date(); updateBattery() }
        if record {
            lastSample = Date()
            cpuHistory.append(cpu); gpuHistory.append(gpu)
            if cpuHistory.count > Self.maxHistory { cpuHistory.removeFirst(cpuHistory.count - Self.maxHistory) }
            if gpuHistory.count > Self.maxHistory { gpuHistory.removeFirst(gpuHistory.count - Self.maxHistory) }
        }
        guard smcAvailable else { return }
        cpuTemp = cpuTempKeys.compactMap(readSMC).filter { $0 > 5 && $0 < 130 }.max()
        gpuTemp = gpuTempKeys.compactMap(readSMC).filter { $0 > 5 && $0 < 130 }.max()
        systemPower = readSMC("PSTR").flatMap { $0 >= 0 && $0 < 500 ? $0 : nil }
        adapterPower = readSMC("PDTR").flatMap { $0 > 0.5 && $0 < 500 ? $0 : nil }
        let n = Int(readSMC("FNum") ?? 0)
        fans = (0..<n).map { i in
            Fan(id: i,
                rpm: readSMC("F\(i)Ac") ?? 0,
                min: readSMC("F\(i)Mn") ?? 0,
                max: readSMC("F\(i)Mx") ?? 0)
        }
    }

    /// Read/write rates from the storage drivers' cumulative byte counters; free space is re-read every 30 s.
    private func updateDisk() {
        let now = Date()
        let t = Self.diskCounters()
        if let p = prevDisk, now.timeIntervalSince(p.time) > 0.1 {
            let dt = now.timeIntervalSince(p.time)
            diskRead = Double(t.read &- p.read) / dt
            diskWrite = Double(t.write &- p.write) / dt
        }
        prevDisk = (t.read, t.write, now)
        if now.timeIntervalSince(lastCapacityCheck) > 30 {
            lastCapacityCheck = now
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                diskTotal = Int64(v.volumeTotalCapacity ?? 0)
                diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            }
        }
    }

    private func updateMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let pages = UInt64(stats.internal_page_count &- stats.purgeable_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            memUsed = pages * page
        }
        var total: UInt64 = 0; var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 { memTotal = total }
        var swap = xsw_usage(); var ssize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &ssize, nil, 0) == 0 { swapUsed = swap.xsu_used }
        memPressure = Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
    }

    /// Download and upload speed from the interface byte counters. The counters are 32-bit, so each interface's delta
    /// is taken with wrapping subtraction (fine at one sample a second). Only physical interfaces (en*, pdp_ip*) count,
    /// so VPN tunnels and loopback don't double-count the same traffic.
    private func updateNetwork() {
        let now = Date()
        let c = Self.netCounters()
        if let p = prevNet, now.timeIntervalSince(p.time) > 0.1 {
            let dt = now.timeIntervalSince(p.time)
            var rx = 0.0, tx = 0.0
            for (name, cur) in c {
                guard let old = p.counters[name] else { continue }
                rx += Double(cur.rx &- old.rx); tx += Double(cur.tx &- old.tx)
            }
            netDown = rx / dt; netUp = tx / dt
        }
        prevNet = (c, now)
    }

    static func netCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               name.hasPrefix("en") || name.hasPrefix("pdp_ip"), let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                result[name] = (d.ifi_ibytes, d.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }
        return result
    }

    private func updateBattery() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { batteryHealth = nil; cycleCount = nil; return }
        defer { IOObjectRelease(svc) }
        func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        let data = prop("BatteryData") as? [String: Any] ?? [:]
        func num(_ k: String) -> Double? { ((data[k] ?? prop(k)) as? NSNumber)?.doubleValue }
        cycleCount = (prop("CycleCount") as? NSNumber)?.intValue
        batteryPercent = (prop("CurrentCapacity") as? NSNumber)?.intValue
        batteryPlugged = (prop("ExternalConnected") as? NSNumber)?.boolValue ?? false
        batteryFull = (prop("FullyCharged") as? NSNumber)?.boolValue ?? false
        // Amperage is a signed 64-bit value; read it as Int64 so a discharge doesn't show up as a huge positive number.
        batteryAmps = Int((prop("Amperage") as? NSNumber)?.int64Value ?? 0)
        let flag = (prop("IsCharging") as? NSNumber)?.boolValue ?? false
        let chargerFlag = ((prop("ChargerData") as? [String: Any])?["IsCharging"] as? NSNumber)?.boolValue ?? false
        // IsCharging can flicker or lag, so also trust the charger's own flag and a clearly positive battery current.
        batteryCharging = !batteryFull && (flag || chargerFlag || (batteryPlugged && batteryAmps > 100))
        func minutes(_ k: String) -> Int? { (prop(k) as? NSNumber).map(\.intValue).flatMap { $0 > 0 && $0 < 6000 ? $0 : nil } }
        batteryMinutes = batteryCharging ? minutes("AvgTimeToFull") : (batteryPlugged ? nil : minutes("AvgTimeToEmpty") ?? minutes("TimeRemaining"))
        chargerWatts = ((prop("AdapterDetails") as? [String: Any])?["Watts"] as? NSNumber).map(\.intValue)
        if let design = num("DesignCapacity"), design > 0, let full = num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity") {
            batteryHealth = min(full / design * 100, 100)
        } else { batteryHealth = nil }
    }

    /// Total bytes read and written since boot, summed over every block storage driver.
    static func diskCounters() -> (read: UInt64, write: UInt64) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0
        var s = IOIteratorNext(it)
        while s != 0 {
            if let stats = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                r &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
        return (r, w)
    }

    /// "12.3 MB/s" style rate; `width` left-pads for the fixed-width menu bar text.
    static func rate(_ bytesPerSecond: Double, width: Int = 0) -> String {
        let mb = bytesPerSecond / 1_000_000
        let s = mb >= 100 ? String(format: "%.0f MB/s", mb)
              : mb >= 1 ? String(format: "%.1f MB/s", mb)
              : String(format: "%.0f KB/s", bytesPerSecond / 1000)
        return String(repeating: " ", count: max(0, width - s.count)) + s
    }

    // Load of each core (and overall) since the previous sample.
    static func cpuLoad(prev: inout [[UInt64]]?) -> (overall: Double, cores: [Double]) {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        // per core: user, system, idle, nice ticks
        let now: [[UInt64]] = (0..<Int(n)).map { core in
            (0..<4).map { UInt64(UInt32(bitPattern: info[core * 4 + $0])) }
        }
        defer { prev = now }
        guard let p = prev, p.count == now.count else { return (0, [Double](repeating: 0, count: now.count)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        let cores: [Double] = zip(now, p).map { cur, old in
            let d = (0..<4).map { cur[$0] &- old[$0] }
            let t = d.reduce(0, +)
            busy += t - d[2]; total += t
            return t == 0 ? 0 : Double(t - d[2]) / Double(t) * 100
        }
        return (total == 0 ? 0 : Double(busy) / Double(total) * 100, cores)
    }

    // GPU utilization from the accelerator's performance statistics (whole-GPU only; macOS has no per-core GPU counters).
    static func gpuLoad() -> (device: Double, renderer: Double, tiler: Double) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return (0, 0, 0) }
        defer { IOObjectRelease(it) }
        var best = (device: 0.0, renderer: 0.0, tiler: 0.0)
        var s = IOIteratorNext(it)
        while s != 0 {
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                func v(_ k: String) -> Double { Double((stats[k] as? Int) ?? 0) }
                best = (max(best.device, v("Device Utilization %")),
                        max(best.renderer, v("Renderer Utilization %")),
                        max(best.tiler, v("Tiler Utilization %")))
            }
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
        return best
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static let gpuCores: Int = {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard s != 0 else { return 0 }
        defer { IOObjectRelease(s) }
        return (IORegistryEntryCreateCFProperty(s, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int) ?? 0
    }()
}


/// Debug: prints every SMC key with the given prefix, with its type, size and raw bytes.
func dumpSMCKeys(prefix: String) {
    guard smc_open() == 0 else { print("SMC not available"); return }
    let count = Int(readSMC("#KEY") ?? 0)
    print("total keys: \(count)")
    for i in 0..<count {
        let k = smc_key_at(UInt32(i))
        guard k != 0 else { continue }
        let name = fourCCString(k)
        guard name.hasPrefix(prefix) else { continue }
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0, type: UInt32 = 0
        guard smc_read(k, &buf, &size, &type) == 0 else { print("\(name)  (unreadable)"); continue }
        let bytes = buf.prefix(Int(size)).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("\(name)  type=\(fourCCString(type))  size=\(size)  bytes=\(bytes)  value=\(readSMC(name).map { String($0) } ?? "-")")
    }
}


// MARK: - Fan writes (only ever called from the root helper)

func smcWriteU8(_ key: String, _ v: UInt8) -> Int32 { var b = [v]; return smc_write(fourCC(key), &b, 1) }

func smcWriteFloat(_ key: String, _ v: Float) -> Int32 {
    let bits = v.bitPattern
    var b = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    return smc_write(fourCC(key), &b, 4)
}

/// Puts every fan back under the system's control.
func restoreAutomaticFans() {
    let n = Int(readSMC("FNum") ?? 0)
    for i in 0..<n { _ = smcWriteFloat("F\(i)Tg", 0); _ = smcWriteU8("F\(i)md", 0) }
}

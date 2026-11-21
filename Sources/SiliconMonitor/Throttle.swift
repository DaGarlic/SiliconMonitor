import Foundation
import IOKit

// Throttle detector: tells you when macOS is holding the chip back, and why.
//
// There is no public API for this, so it combines three private-but-unprivileged sources:
//   - the system thermal pressure level (the `com.apple.system.thermalpressurelevel` notify state)
//   - IOReport "GPU Stats": GPU_CLTM (closed-loop thermal management caps), PMU_RC (the PMU's "lost performance
//     reason", thermal or emergency, per GPU/fabric zone), PWRCTRL (what the GPU power controller is doing) and
//     GPU_PPM (the power budget as a share of the maximum)
//   - IOReport "CPU Stats": time spent in each CPU performance state, turned into an average clock speed using
//     the frequency tables in the IORegistry (`pmgr`, voltage-states*-sram). The clock is shown for context; the
//     CPU has no "reason" channel, so a CPU limit shows up through the thermal pressure level.
// Everything is loaded at runtime and degrades to "not available" when a source is missing.

// MARK: IOReport

private final class IOReport: @unchecked Sendable {
    private typealias CopyInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeRawPointer?
    private typealias Samples = @convention(c) (UnsafeRawPointer, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Text = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias Residency = @convention(c) (CFDictionary, Int32) -> Int64

    private let subscribe: Subscribe, samples: Samples, delta: Delta
    private let subGroup: Text, channelName: Text
    private let stateCount: Count, stateName: StateName, residency: Residency

    /// One channel group: a state histogram per channel, over the last interval.
    struct Channel {
        let subgroup: String
        let name: String
        let states: [(name: String, time: Double)]
        var total: Double { states.reduce(0) { $0 + $1.time } }
        func time(_ names: some Sequence<String>) -> Double {
            let set = Set(names)
            return states.reduce(0) { set.contains($1.name) ? $0 + $1.time : $0 }
        }
    }

    private struct Source {
        let subscription: UnsafeRawPointer
        let channels: CFMutableDictionary
        var previous: CFDictionary?
    }
    private var sources: [String: Source] = [:]

    init?(groups: [String]) {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _ type: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: type) } }
        guard let copy = load("IOReportCopyChannelsInGroup", CopyInGroup.self),
              let subscribe = load("IOReportCreateSubscription", Subscribe.self),
              let samples = load("IOReportCreateSamples", Samples.self),
              let delta = load("IOReportCreateSamplesDelta", Delta.self),
              let sub = load("IOReportChannelGetSubGroup", Text.self),
              let name = load("IOReportChannelGetChannelName", Text.self),
              let count = load("IOReportStateGetCount", Count.self),
              let stateName = load("IOReportStateGetNameForIndex", StateName.self),
              let residency = load("IOReportStateGetResidency", Residency.self) else { return nil }
        self.subscribe = subscribe; self.samples = samples; self.delta = delta
        subGroup = sub; channelName = name; stateCount = count; self.stateName = stateName; self.residency = residency
        for group in groups {
            guard let wanted = copy(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { continue }
            var subscribed: Unmanaged<CFMutableDictionary>?
            guard let s = subscribe(nil, wanted, &subscribed, 0, nil), let channels = subscribed?.takeRetainedValue() else { continue }
            sources[group] = Source(subscription: s, channels: channels, previous: nil)
        }
        if sources.isEmpty { return nil }
    }

    /// The channels of `group` for the time since the previous call (nil on the first call).
    func read(_ group: String) -> [Channel]? {
        guard var source = sources[group],
              let now = samples(source.subscription, source.channels, nil)?.takeRetainedValue() else { return nil }
        defer { source.previous = now; sources[group] = source }
        guard let before = source.previous,
              let diff = delta(before, now, nil)?.takeRetainedValue(),
              let items = (diff as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        return items.map { item in
            let c = item as CFDictionary
            let n = max(Int(stateCount(c)), 0)
            let states = (0..<n).map { i in
                (name: stateName(c, Int32(i))?.takeUnretainedValue() as String? ?? "", time: Double(max(residency(c, Int32(i)), 0)))
            }
            return Channel(subgroup: subGroup(c)?.takeUnretainedValue() as String? ?? "",
                           name: channelName(c)?.takeUnretainedValue() as String? ?? "", states: states)
        }
    }
}

/// CPU frequency tables: the IORegistry `pmgr` node has `voltage-states*-sram` lists of (frequency, voltage) pairs.
/// A cluster is matched to the table with as many entries as it has performance states.
private enum FrequencyTables {
    static let byCount: [Int: [Double]] = {   // entries -> MHz per state, lowest first
        var result: [Int: [Double]] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &name)
            guard String(cString: name) == "pmgr" else { continue }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else { continue }
            for (key, value) in dict where key.hasPrefix("voltage-states") && key.hasSuffix("-sram") {
                guard let data = value as? Data, data.count >= 16 else { continue }
                let raw = stride(from: 0, to: data.count - 7, by: 8).map { offset in
                    Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
                }
                guard raw.count > 3, (raw.max() ?? 0) > 1_000_000 else { continue }   // skips tables of 1s (not frequencies)
                let mhz = raw.map { $0 > 100_000_000 ? $0 / 1e6 : $0 / 1e3 }          // Hz or kHz
                if result[mhz.count] == nil || mhz.max()! > result[mhz.count]!.max()! { result[mhz.count] = mhz }
            }
        }
        return result
    }()
}

// MARK: Model

struct ThrottleEvent: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date?
    var causes: [String]
    var peakCPUTemp: Double?
    var peakGPUTemp: Double?
    var peakPower: Double?
    var cpuLoad: Double
    var gpuLoad: Double
}

/// What one tick of data says about limits. Pure, so it can be tested.
struct ThrottleReading: Equatable {
    var thermalLevel = 0                 // 0 nominal ... 4 sleeping
    var gpuCLTM = 0.0                    // 0...1 share of time under a closed-loop thermal cap
    var gpuReason: String?               // PMU lost-performance reason with the most time, if any
    var gpuReasonShare = 0.0
    var gpuThermalCtl = 0.0              // share of time the GPU power controller reports a thermal limit
    var gpuPowerCtl = 0.0                // ... a power-budget limit
    var gpuBudget = 1.0                  // average power budget, 0...1 of maximum
    var gpuLoad = 0.0                    // 0...100

    static let levelNames = ["Nominal", "Moderate", "Heavy", "Critical", "Emergency"]

    /// The causes that are active, most important first.
    var causes: [String] {
        var out: [String] = []
        if thermalLevel > 0 { out.append("Thermal pressure: \(Self.levelNames[min(thermalLevel, 4)])") }
        if gpuCLTM > 0.03 || gpuThermalCtl > 0.05 || (gpuReason?.hasSuffix("_TH") == true && gpuReasonShare > 0.03) {
            out.append("GPU thermal limit")
        }
        if gpuReason?.hasSuffix("_EMT") == true, gpuReasonShare > 0.03 { out.append("GPU emergency thermal limit") }
        if gpuPowerCtl > 0.05, gpuLoad > 40 { out.append("GPU power limit") }
        if gpuBudget < 0.7, gpuLoad > 50 { out.append("GPU power budget \(Int(gpuBudget * 100))%") }
        return out
    }
}

@MainActor
final class ThrottleMonitor: ObservableObject {
    struct Clock: Equatable { let name: String; let mhz: Double; let maxMHz: Double; let active: Double }

    @Published private(set) var available = false
    @Published private(set) var causes: [String] = []
    @Published private(set) var thermalLevel = 0
    @Published private(set) var clocks: [Clock] = []
    @Published private(set) var gpuBudget = 1.0
    @Published private(set) var events: [ThrottleEvent] = []
    @Published private(set) var current: ThrottleEvent?
    /// The top-tier clock as a share of its maximum, one value per tick, for the Clocks graph (0...100).
    @Published private(set) var clockHistory: [Double] = []
    /// Whether macOS was limiting performance at each of those ticks, so the graph can shade the throttled stretches.
    @Published private(set) var limitedHistory: [Bool] = []

    var limited: Bool { !causes.isEmpty }

    private let report: IOReport?
    private var clearTicks = 0
    private var currentIsFake = false   // the debug switch was on during this event, so it is not kept
    private let notifyToken: Int32?
    private typealias NotifyGet = @convention(c) (Int32, UnsafeMutablePointer<UInt64>) -> UInt32
    private let notifyGet: NotifyGet?

    init() {
        report = IOReport(groups: ["CPU Stats", "GPU Stats"])
        var token: Int32 = 0
        typealias Register = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
        let handle = dlopen(nil, RTLD_NOW)
        if let r = dlsym(handle, "notify_register_check"), let g = dlsym(handle, "notify_get_state"),
           unsafeBitCast(r, to: Register.self)("com.apple.system.thermalpressurelevel", &token) == 0 {
            notifyToken = token
            notifyGet = unsafeBitCast(g, to: NotifyGet.self)
        } else {
            notifyToken = nil; notifyGet = nil
        }
        available = report != nil || notifyToken != nil
        if let data = UserDefaults.standard.data(forKey: "throttleEvents"),
           let saved = try? JSONDecoder().decode([ThrottleEvent].self, from: data) { events = saved }
    }

    private func thermalPressure() -> Int {
        if let notifyToken, let notifyGet {
            var state: UInt64 = 0
            if notifyGet(notifyToken, &state) == 0 { return Int(min(state, 4)) }
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        default: return 3
        }
    }

    /// Called once per Monitor tick.
    func tick(cpuLoad: Double, gpuLoad: Double, cpuTemp: Double?, gpuTemp: Double?, power: Double?) {
        guard available else { return }
        var reading = ThrottleReading()
        // Debug aid: `defaults write local.siliconmonitor fakeThrottle -bool true` reports moderate thermal pressure
        // (and `defaults delete local.siliconmonitor fakeThrottle` ends it), to see the banner, tint and graph shading.
        let fake = UserDefaults.standard.bool(forKey: "fakeThrottle")
        reading.thermalLevel = fake ? 2 : thermalPressure()
        reading.gpuLoad = gpuLoad
        thermalLevel = reading.thermalLevel
        if let gpu = report?.read("GPU Stats") { Self.fill(&reading, gpu: gpu); gpuBudget = reading.gpuBudget }
        if let cpu = report?.read("CPU Stats") { clocks = Self.clocks(from: cpu) }

        causes = reading.causes
        if let c = topTierClock, c.maxMHz > 0 {
            clockHistory.append(min(c.mhz / c.maxMHz * 100, 100))
            limitedHistory.append(limited)
            let extra = clockHistory.count - (Monitor.maxHistory + 2)
            if extra > 0 { clockHistory.removeFirst(extra); limitedHistory.removeFirst(extra) }
        }
        if limited {
            clearTicks = 0
            if fake { currentIsFake = true }
            if current == nil {
                current = ThrottleEvent(start: Date(), causes: causes, cpuLoad: cpuLoad, gpuLoad: gpuLoad)
            }
            current?.causes = Array(Set(current!.causes).union(causes)).sorted()
            current?.peakCPUTemp = max(current?.peakCPUTemp ?? 0, cpuTemp ?? 0)
            current?.peakGPUTemp = max(current?.peakGPUTemp ?? 0, gpuTemp ?? 0)
            current?.peakPower = max(current?.peakPower ?? 0, power ?? 0)
        } else if var event = current {
            clearTicks += 1
            if Double(clearTicks) * Monitor.sampleInterval >= 5 {             // clear for 5 s in a row ends it, so flicker is one event
                event.end = Date().addingTimeInterval(-5)
                if !currentIsFake {              // faked events from the debug switch never reach the history
                    events.insert(event, at: 0)
                    events = Array(events.prefix(20))
                    if let data = try? JSONEncoder().encode(events) { UserDefaults.standard.set(data, forKey: "throttleEvents") }
                }
                current = nil
                currentIsFake = false
            }
        }
    }

    /// Starts the Clocks graph over (the sample spacing changed).
    func resetHistory() { clockHistory = []; limitedHistory = [] }

    func clearHistory() {
        events = []
        UserDefaults.standard.removeObject(forKey: "throttleEvents")
    }

    // MARK: Parsing

    private static func fill(_ r: inout ThrottleReading, gpu: [IOReport.Channel]) {
        for ch in gpu {
            switch ch.name {
            case "GPU_CLTM":
                let capped = ch.states.filter { $0.name.hasPrefix("P") }.reduce(0) { $0 + $1.time }
                let total = capped + ch.time(["NO_CLTM"])
                r.gpuCLTM = total > 0 ? capped / total : 0
            case "PMU_RC":
                let total = ch.total
                let reasons = ch.states.filter { $0.name != "NONE" && $0.name != "INVALID" }
                if total > 0, let top = reasons.max(by: { $0.time < $1.time }), top.time > 0 {
                    r.gpuReason = top.name
                    r.gpuReasonShare = reasons.reduce(0) { $0 + $1.time } / total
                }
            case "PWRCTRL":
                let total = ch.total - ch.time(["IDLE_OFF", "STANDBY"])
                if total > 0 {
                    r.gpuThermalCtl = ch.time(["CLTMLIMI"]) / total
                    r.gpuPowerCtl = ch.time(["PPMLIMIT"]) / total
                }
            case "GPU_PPM":
                let total = ch.total
                if total > 0 {
                    let weighted = ch.states.enumerated().reduce(0.0) { $0 + $1.element.time * (Double($1.offset) * 10 + 5) }
                    r.gpuBudget = min(weighted / total / 100, 1)
                }
            default: break
            }
        }
    }

    /// Average active clock per CPU cluster, from the time spent in each "V<index>P<n>" performance state.
    private static func clocks(from cpu: [IOReport.Channel]) -> [Clock] {
        var out: [Clock] = []
        for ch in cpu where ch.subgroup == "CPU Complex Performance States" {
            guard ch.name.range(of: #"^[EPMS]CPU\d*$"#, options: .regularExpression) != nil else { continue }
            var byIndex: [Int: Double] = [:]
            for s in ch.states where s.name.hasPrefix("V") {
                if let i = Int(s.name.dropFirst().prefix { $0.isNumber }) { byIndex[i] = s.time }
            }
            let count = ch.states.filter { $0.name.hasPrefix("V") }.count
            guard count > 0, let table = FrequencyTables.byCount[count] else { continue }
            let active = byIndex.values.reduce(0, +)
            guard active > 0, ch.total > 0 else { continue }
            var mhz = 0.0
            for (i, time) in byIndex where i < table.count { mhz += table[i] * time }
            out.append(Clock(name: ch.name, mhz: mhz / active, maxMHz: table.max() ?? 0, active: active / ch.total))
        }
        return out
    }

    /// The busiest top-tier ("P") cluster: the one that throttles first, so the one the graph follows.
    var topTierClock: Clock? { clocks.filter { $0.name.hasPrefix("P") }.max(by: { $0.active < $1.active }) ?? headlineClock }

    /// The busiest cluster's clock, for the one-line summary.
    var headlineClock: Clock? { clocks.max(by: { $0.active < $1.active }) }
}

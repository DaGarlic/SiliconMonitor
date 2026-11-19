import CoreAudio
import Foundation
import os

// Listens to whatever the Mac is playing and reports beats, for the logo's Music mode.
//
// It uses a Core Audio process tap (macOS 14.2+): a global stereo tap of the system output, wrapped in a private
// aggregate device so an IOProc can read it. The tap is unmuted (it only listens). The first use makes macOS ask
// for "audio capture" permission (Info.plist needs NSAudioCaptureUsageDescription). If the permission is denied the
// tap delivers silence, so the logo just stays at its floor.

/// Thread-safe mailbox between the audio thread (writes) and the logo queue (reads).
final class BeatMailbox: @unchecked Sendable {
    struct Beat { let id: Int; let strength: Double; let age: Double }   // strength 0...1, age in seconds
    private let state = OSAllocatedUnfairLock(initialState: (id: 0, strength: 0.0, at: Date.distantPast, lastSound: Date.distantPast))

    func post(strength: Double) { state.withLock { $0.id += 1; $0.strength = strength; $0.at = Date() } }
    func heardSound() { state.withLock { $0.lastSound = Date() } }
    func latest() -> Beat { state.withLock { Beat(id: $0.id, strength: $0.strength, age: -$0.at.timeIntervalSinceNow) } }
    func secondsSinceSound() -> Double { state.withLock { -$0.lastSound.timeIntervalSinceNow } }
}

/// Bass-band onset detector: a one-pole low-pass keeps roughly the kick/bass, and a beat is a block of it that is
/// clearly louder than the recent average.
struct BeatDetector {
    private var lowPass: Float = 0
    private var average: Float = 0.0005       // slow average of block energy (about 1.5 s)
    private var previous: Float = 0
    private var sinceBeat = 1.0
    private var coefficient: Float = 0.02

    mutating func configure(sampleRate: Double) {
        // cut-off about 150 Hz
        coefficient = Float(1 - exp(-2 * Double.pi * 150 / max(sampleRate, 8000)))
    }

    /// `samples`: mono. Returns a beat strength (0...1) if this block starts one, and the block's loudness.
    mutating func process(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> (beat: Double?, loud: Float) {
        guard !samples.isEmpty else { return (nil, 0) }
        var energy: Float = 0, peak: Float = 0
        for s in samples {
            lowPass += coefficient * (s - lowPass)
            energy += lowPass * lowPass
            peak = max(peak, abs(s))
        }
        energy /= Float(samples.count)
        let blockSeconds = Double(samples.count) / sampleRate
        sinceBeat += blockSeconds
        let blocksPerWindow = Float(max(1.5 / blockSeconds, 1))
        defer {
            average += (energy - average) / blocksPerWindow
            previous = energy
        }
        let rising = energy > previous * 1.15
        let loudEnough = energy > 0.000_02                      // about -47 dB: ignore near-silence
        if rising, loudEnough, energy > average * 1.5, sinceBeat > 0.17 {
            sinceBeat = 0
            let ratio = Double(energy / max(average, 1e-7))
            return (min(max((ratio - 1.5) / 3, 0), 1), peak)    // 1.5x average = soft hit, 4.5x or more = full
        }
        return (nil, peak)
    }
}

@available(macOS 14.2, *)
final class MusicTap: @unchecked Sendable {
    let mailbox = BeatMailbox()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "siliconmonitor.musictap", qos: .userInteractive)
    private var detector = BeatDetector()
    private var scratch = [Float]()

    enum Permission { case granted, denied, unknown }

    /// The audio capture permission, read through the private TCC preflight call (there is no public one).
    /// `.unknown` means the user has not been asked yet.
    static var permission: Permission {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    var isRunning: Bool { procID != nil }

    deinit { stop() }

    /// Returns false if the tap could not be created.
    @discardableResult
    func start() -> Bool {
        guard procID == nil else { return true }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "SiliconMonitor music tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return false }

        var outputUID: String?
        if let device = Self.defaultOutputDevice() { outputUID = Self.uid(of: device) }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SiliconMonitor music",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let outputUID {   // gives the aggregate a clock
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { stop(); return false }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let rate = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr && format.mSampleRate > 0
            ? format.mSampleRate : 48000
        detector = BeatDetector()
        detector.configure(sampleRate: rate)

        let box = mailbox
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [unowned self] _, input, _, _, _ in
            handle(input, sampleRate: rate, mailbox: box)
        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else { stop(); return false }
        return true
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    // MARK: Audio thread

    private func handle(_ input: UnsafePointer<AudioBufferList>, sampleRate: Double, mailbox: BeatMailbox) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
        for i in 0..<frames {     // mono mix of the interleaved channels
            var sum: Float = 0
            for c in 0..<channels { sum += samples[i * channels + c] }
            scratch[i] = sum / Float(channels)
        }
        let result = scratch.withUnsafeBufferPointer { detector.process(UnsafeBufferPointer(rebasing: $0[0..<frames]), sampleRate: sampleRate) }
        if result.loud > 0.003 { mailbox.heardSound() }
        if let strength = result.beat { mailbox.post(strength: strength) }
    }

    // MARK: Helpers

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

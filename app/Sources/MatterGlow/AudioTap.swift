import CoreAudio
import Foundation

/// Host clock in seconds (the clock audio timestamps use).
func hostSeconds(_ hostTime: UInt64 = AudioGetCurrentHostTime()) -> Double {
    Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
}

/// Captures one app's audio output with a Core Audio process tap (macOS 14.2+).
/// Needs the "System Audio Recording" permission; without it the samples are silent.
final class AudioTap: @unchecked Sendable {
    /// Mono samples, the host time of the first one, and the sample rate. Called on `queue`.
    var onSamples: (@Sendable ([Float], Double, Double) -> Void)?

    private let queue: DispatchQueue
    // Core Audio syncs onto the IO queue while creating the callback, so it must
    // not be `queue` (start() runs there): that deadlocks.
    private let ioQueue = DispatchQueue(label: "matterglow.tap.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { stop() }

    func start(pid: pid_t) throws {
        stop()
        let process = try Self.processObject(for: pid)

        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "Matter Glow"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        var format = AudioStreamBasicDescription()
        try check(getProperty(tapID, kAudioTapPropertyFormat, &format), "read tap format")
        let channels = Int(format.mChannelsPerFrame)

        // The aggregate device needs a real device to clock it; nothing is played
        // through it. Built-in speakers are always there (AirPlay can't be used).
        guard let clock = Self.clockDeviceUID() else { throw TapError("No audio device to run the capture") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Matter Glow Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clock]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")
        // Samples arrive at the clock device's rate (e.g. 44.1 kHz for built-in
        // speakers), not the tap's own (48 kHz): the tap is resampled to it.
        var sampleRate: Float64 = 0
        _ = getProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, &sampleRate)
        if sampleRate <= 0 { sampleRate = format.mSampleRate }
        let rate = sampleRate

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, inputTime, _, _ in
            guard let self, let onSamples else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            var mono: [Float]
            if buffers.count == 1 {
                // Interleaved: average the channels of each frame.
                let samples = data.assumingMemoryBound(to: Float.self)
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, channels)
                mono = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += samples[f * channels + c] }
                    mono[f] = sum / Float(max(1, channels))
                }
            } else {
                // One buffer per channel.
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                mono = [Float](repeating: 0, count: frames)
                for buffer in buffers {
                    guard let d = buffer.mData else { continue }
                    let samples = d.assumingMemoryBound(to: Float.self)
                    for f in 0..<frames { mono[f] += samples[f] / Float(buffers.count) }
                }
            }
            let time = inputTime.pointee.mFlags.contains(.hostTimeValid)
                ? hostSeconds(inputTime.pointee.mHostTime) : hostSeconds()
            let samples = mono
            queue.async { onSamples(samples, time, rate) }
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start capture")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Built-in output if there is one, else the default output unless it's AirPlay.
    private static func clockDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        var fallback: String?
        for device in devices {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize)
            guard streamSize > 0 else { continue } // no outputs
            var transport: UInt32 = 0
            var uid: CFString = "" as CFString
            _ = getProperty(device, kAudioDevicePropertyTransportType, &transport)
            _ = getProperty(device, kAudioDevicePropertyDeviceUID, &uid)
            if transport == kAudioDeviceTransportTypeBuiltIn { return uid as String }
            if transport != kAudioDeviceTransportTypeAirPlay, transport != kAudioDeviceTransportTypeAggregate { fallback = fallback ?? uid as String }
        }
        return fallback
    }

    private static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "find Music's audio")
        guard object != kAudioObjectUnknown else { throw TapError("Music has no audio process yet") }
        return object
    }
}

struct TapError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw TapError("Could not \(what) (\(status))") }
}

func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
}

/// The current default output device: its UID, whether it is AirPlay, and the
/// latency it reports (AirPlay reports 0 even though it buffers for much longer).
func defaultOutputDevice() -> (uid: String, isAirPlay: Bool, latency: Double)? {
    var device = AudioObjectID(kAudioObjectUnknown)
    guard getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) == noErr
    else { return nil }
    var uid: CFString = "" as CFString
    var transport: UInt32 = 0
    var latency: UInt32 = 0, safety: UInt32 = 0
    var rate: Float64 = 48000
    _ = getProperty(device, kAudioDevicePropertyDeviceUID, &uid)
    _ = getProperty(device, kAudioDevicePropertyTransportType, &transport)
    _ = getProperty(device, kAudioDevicePropertyLatency, &latency, scope: kAudioObjectPropertyScopeOutput)
    _ = getProperty(device, kAudioDevicePropertySafetyOffset, &safety, scope: kAudioObjectPropertyScopeOutput)
    _ = getProperty(device, kAudioDevicePropertyNominalSampleRate, &rate)
    return (uid as String, transport == kAudioDeviceTransportTypeAirPlay, Double(latency + safety) / max(rate, 1))
}

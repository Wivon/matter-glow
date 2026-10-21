import Accelerate
import AVFoundation

/// A stretch of audio and the host time of its first sample.
struct Recording: Sendable {
    var start: Double
    var rate: Double
    var samples: [Float] = []
}

/// Measures how long the speakers take to play what Music sends (AirPlay buffers
/// for ~2 s and doesn't report it): records the room with the microphone and finds
/// the lag between it and the tapped audio by cross-correlating the waveforms
/// (GCC-PHAT). Waveforms don't repeat bar after bar the way beats do, so the
/// match is unambiguous, and the phase weighting copes with echo and speaker EQ.
enum Calibrator {
    enum Failure: Error, CustomStringConvertible {
        case noMicrophone, noMusic, unclear
        var description: String {
            switch self {
            case .noMicrophone: "Microphone access is needed to calibrate"
            case .noMusic: "Couldn't hear the music - is it playing?"
            case .unclear: "Couldn't line up the sound - try again a bit louder"
            }
        }
    }

    static let maxDelay = 3.0
    private static let rate = 8000.0

    static func measure(with rhythm: Rhythm, seconds: Double = 8) async -> Result<Double, Failure> {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return .failure(.noMicrophone) }
        let mic = MicListener()
        rhythm.beginRecording()
        do { try mic.start() } catch { return .failure(.noMicrophone) }
        try? await Task.sleep(for: .seconds(seconds))
        mic.stop()
        guard let tapped = await rhythm.endRecording() else { return .failure(.noMusic) }
        return estimateDelay(tapped: tapped, heard: mic.recording())
    }

    /// The delay (0-3 s) after which `heard` plays what `tapped` contains.
    static func estimateDelay(tapped: Recording, heard: Recording) -> Result<Double, Failure> {
        let tap = resample(tapped), mic = resample(heard)
        func loud(_ x: [Float]) -> Bool { x.count > Int(rate) && vDSP.rootMeanSquare(x) > 1e-4 }
        guard loud(tap), loud(mic) else { return .failure(.noMusic) }

        var n = 1
        while n < tap.count + mic.count { n *= 2 }
        let forward = try! vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        let inverse = try! vDSP.DiscreteFourierTransform(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        let zeros = [Float](repeating: 0, count: n)
        func spectrum(_ x: [Float]) -> (real: [Float], imaginary: [Float]) {
            forward.transform(real: x + [Float](repeating: 0, count: n - x.count), imaginary: zeros)
        }
        let (tr, ti) = spectrum(tap), (mr, mi) = spectrum(mic)

        // conj(M) * T, keeping only the phase.
        var re = [Float](repeating: 0, count: n), im = re
        for k in 0..<n {
            let a = mr[k] * tr[k] + mi[k] * ti[k]
            let b = mr[k] * ti[k] - mi[k] * tr[k]
            let m = (a * a + b * b).squareRoot() + 1e-9
            re[k] = a / m
            im[k] = b / m
        }
        let correlation = inverse.transform(real: re, imaginary: im).real

        // c[m] peaks where heard[j] matches tapped[j + m], i.e. at
        // m = (heard.start - tapped.start - delay) * rate (negative values wrap).
        let shift = (heard.start - tapped.start) * rate
        var best = 0.0, bestValue: Float = -.infinity
        var values: [Float] = []
        for step in 0...Int(maxDelay * rate) {
            let delay = Double(step) / rate
            let m = Int((shift - delay * rate).rounded())
            let v = correlation[(m % n + n) % n]
            values.append(v)
            if v > bestValue { bestValue = v; best = delay }
        }
        let mean = values.reduce(0, +) / Float(values.count)
        let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        guard spread > 0, (bestValue - mean) / spread > 8 else { return .failure(.unclear) }
        return .success(best)
    }

    /// Linear resampling to 8 kHz, plenty for timing and much cheaper to correlate.
    private static func resample(_ r: Recording) -> [Float] {
        guard r.rate > 0, !r.samples.isEmpty else { return [] }
        let count = Int(Double(r.samples.count) * rate / r.rate)
        let ratio = r.rate / rate
        return (0..<count).map { i in
            let x = Double(i) * ratio
            let j = Int(x), f = Float(x - Double(j))
            let a = r.samples[j], b = r.samples[min(j + 1, r.samples.count - 1)]
            return a + (b - a) * f
        }
    }
}

/// Raw microphone audio, timestamped on the same host clock as the tap.
private final class MicListener: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "matterglow.mic")
    private var collected: Recording?

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // macOS 27 deprecates installTap for a variant that reports errors, which
        // the SDK only exposes under its raw "refined for Swift" name so far.
        try input.__installTap(onBus: 0, bufferSize: 8192, format: format, error: ()) { [weak self] buffer, time in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let t = time.isHostTimeValid ? hostSeconds(time.hostTime) : hostSeconds()
            queue.async {
                if self.collected == nil { self.collected = Recording(start: t, rate: format.sampleRate) }
                self.collected!.samples += samples
            }
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func recording() -> Recording {
        queue.sync { collected ?? Recording(start: 0, rate: 0) }
    }
}

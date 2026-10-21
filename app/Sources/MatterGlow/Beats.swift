import Accelerate
import Foundation

/// One analysis frame: overall onset strength (bass weighted up, for the tempo)
/// plus the onset strength in the kick/808 band and the snare/clap band.
struct Onset: Sendable {
    let time: Double
    let value: Float
    let bass: Float
    let snare: Float
}

/// Turns audio into an onset envelope (spectral flux, one value per ~11 ms):
/// high where a new sound starts, low during steady parts. Not thread-safe; use
/// from one queue.
final class OnsetDetector {
    private let size = 1024
    private let hop = 512
    private let sampleRate: Double
    private let window: [Float]
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let zeros: [Float]
    private let bassBins: Int
    private let snareBins: ClosedRange<Int>
    private let airBins: ClosedRange<Int>
    private var previous: [Float]
    private var previousBass: Float = 0
    private var snareHistory: [Float] = [0, 0, 0, 0, 0] // snare-band amplitude, last 5 frames
    private var previousAir: Float = 0
    private var buffer: [Float] = []
    private var bufferStart = 0.0 // host time of buffer[0]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        dft = try! vDSP.DiscreteFourierTransform(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        zeros = [Float](repeating: 0, count: size)
        previous = [Float](repeating: 0, count: size / 2)
        let binWidth = sampleRate / Double(size)
        bassBins = Int(160 / binWidth) + 1 // kick and 808: up to ~160 Hz
        // Snares and claps are noise bursts: they jump at a few kHz and above 8 kHz
        // at once. Voices jump only in the mids, hi-hats (quieter) only up high.
        snareBins = Int(1500 / binWidth)...Int(6000 / binWidth)
        airBins = Int(8000 / binWidth)...min(size / 2 - 1, Int(16000 / binWidth))
    }

    /// Feed samples (with the host time of the first); returns one Onset per hop.
    func process(_ samples: [Float], at time: Double) -> [Onset] {
        let expected = bufferStart + Double(buffer.count) / sampleRate
        if buffer.isEmpty || abs(time - expected) > 0.05 { // first call or a gap: resync
            buffer.removeAll()
            bufferStart = time
        }
        buffer.append(contentsOf: samples)

        var out: [Onset] = []
        var real = [Float](repeating: 0, count: size), imag = real
        let scale = 4 / Float(size)
        while buffer.count >= size {
            let frame = vDSP.multiply(buffer[0..<size], window)
            dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &real, outputImaginary: &imag)
            // Tempo uses log-compressed flux (every onset counts). The instrument
            // bands use jumps in plain amplitude instead, so faint spill (a snare's
            // body in the bass, a vocal swelling in the mids) can't pass for a hit.
            var flux: Float = 0, bassEnergy: Float = 0, snareEnergy: Float = 0, airEnergy: Float = 0
            for k in 1..<size / 2 {
                let power = scale * scale * (real[k] * real[k] + imag[k] * imag[k])
                let magnitude = log1p(100 * power.squareRoot())
                let rise = magnitude - previous[k]
                if rise > 0 { flux += k < bassBins ? 4 * rise : rise }
                previous[k] = magnitude
                if k < bassBins { bassEnergy += power }
                if snareBins.contains(k) { snareEnergy += power }
                if airBins.contains(k) { airEnergy += power }
            }
            let bass = bassEnergy.squareRoot(), snare = snareEnergy.squareRoot(), air = airEnergy.squareRoot()
            // A snare's energy arrives within one frame; a voice swells over several.
            let jump = max(0, snare - snareHistory[4])
            let sharpness = jump / max(snare - snareHistory[0], jump, 1e-9)
            // Geometric mean: only high when the mids and the air jump together.
            let airJump = max(0, air - previousAir)
            out.append(Onset(time: bufferStart + Double(size / 2) / sampleRate, value: flux,
                             bass: max(0, bass - previousBass), snare: (jump * sharpness * airJump).squareRoot()))
            previousBass = bass
            snareHistory.removeFirst()
            snareHistory.append(snare)
            previousAir = air
            buffer.removeFirst(hop)
            bufferStart += Double(hop) / sampleRate
        }
        return out
    }
}

/// Finds the tempo and beat phase in an onset envelope and predicts beat times.
/// Not thread-safe; use from one queue.
final class BeatTracker {
    private(set) var period: Double?      // seconds per beat
    private(set) var confidence = 0.0     // how periodic the recent audio is at that tempo
    private(set) var hasBeat = false
    private var lastBeat: Double?         // host time of a recent beat
    private var phaseCandidate: (time: Double, count: Int)?
    private var lockedAt: Double?         // when the current tempo was first chosen
    private var switchVotes = 0
    private var quietSince: Double?

    private var times: [Double] = []
    private var values: [Float] = []
    private let history = 8.0             // seconds of envelope kept
    private static let siblingRatios: [Double] = [0.5, 2, 1.5, 2.0 / 3, 4.0 / 3, 0.75, 3, 1.0 / 3]

    var bpm: Double? { period.map { 60 / $0 } }

    func add(_ onsets: [Onset]) {
        for o in onsets {
            times.append(o.time)
            values.append(o.value)
        }
        if let last = times.last, let cut = times.firstIndex(where: { $0 > last - history }), cut > 0 {
            times.removeFirst(cut)
            values.removeFirst(cut)
        }
    }

    /// Forget everything, e.g. when a new song starts.
    func reset() {
        period = nil
        confidence = 0
        hasBeat = false
        lastBeat = nil
        phaseCandidate = nil
        lockedAt = nil
        switchVotes = 0
        quietSince = nil
        times.removeAll()
        values.removeAll()
    }

    /// Re-estimate tempo and phase; call a few times per second.
    func update() {
        guard times.count > 300, let dt = frameDuration, let now = times.last else { return }
        let x = novelty()

        // Autocorrelation out to 4 beats of the slowest tempo (60 BPM).
        let minLag = Int(60 / 200 / dt), maxLag = Int(60 / 60 / dt)
        guard x.count > maxLag * 2 else { return }
        let longest = min(x.count / 2, maxLag * 4)
        var r = [Double](repeating: 0, count: longest + 2)
        for lag in minLag...longest + 1 {
            var sum: Float = 0
            vDSP_dotpr(Array(x[lag...]), 1, Array(x[..<(x.count - lag)]), 1, &sum, vDSP_Length(x.count - lag))
            r[lag] = Double(sum) / Double(x.count - lag)
        }
        let mean = r[minLag...maxLag].reduce(0, +) / Double(maxLag - minLag + 1)
        guard mean > 0 else { return }

        // A real beat also lines up at 2, 3 and 4 beats, while hi-hat rolls,
        // triplets and syncopated 808s mostly don't: score each tempo with its
        // multiples, nudged towards ~120 BPM to settle half/double time.
        func peak(_ lag: Int) -> Double { r[max(minLag, lag - 1)...min(longest, lag + 1)].max() ?? 0 }
        func score(_ lag: Int) -> Double {
            var s = 0.0
            for k in 1...4 where k * lag <= longest { s += peak(k * lag) / Double(k) }
            let bpm = 60 / (Double(lag) * dt)
            return s * exp(-0.5 * pow(log2(bpm / 120) / 0.7, 2))
        }
        func best(in lags: ClosedRange<Int>) -> Int { lags.max { score($0) < score($1) }! }
        func refined(_ lag: Int) -> Double { // parabolic interpolation for a sub-frame period
            let (a, b, c) = (r[lag - 1], r[lag], r[lag + 1])
            let shift = (a - 2 * b + c) != 0 ? 0.5 * (a - c) / (a - 2 * b + c) : 0
            return (Double(lag) + max(-0.5, min(0.5, shift))) * dt
        }

        let global = best(in: minLag...maxLag)
        if let current = period, let lockedAt {
            // Follow small drifts around the locked tempo.
            let lag = current / dt
            let local = best(in: max(minLag, Int(lag * 0.96))...min(maxLag, Int((lag * 1.04).rounded(.up))))
            // Switch only for a clearly better tempo, held for 3 s. Within a song
            // never to double/half/3:2/4:3 of the current one - those are the same
            // beat counted differently - except right after locking, when the
            // first guess may still be the wrong one of the two.
            let ratio = Double(global) / lag
            let sibling = Self.siblingRatios.contains { abs(ratio / $0 - 1) < 0.05 }
            let settling = now - lockedAt < 6
            if abs(ratio - 1) > 0.05, score(global) > score(local) * 1.25, settling || !sibling {
                switchVotes += 1
            } else {
                switchVotes = 0
            }
            if switchVotes >= (settling ? 4 : 12) {
                period = refined(global)
                lastBeat = nil
                switchVotes = 0
                confidence = r[global] / mean
            } else {
                period = current * 0.8 + refined(local) * 0.2
                confidence = r[local] / mean
            }
        } else {
            period = refined(global)
            lockedAt = now
            confidence = r[global] / mean
        }

        // Beat on above 1.6, off only after 1 s below 1.3, so breaks don't flicker.
        if confidence > 1.6 {
            hasBeat = true
            quietSince = nil
        } else if confidence < 1.3 {
            if quietSince == nil { quietSince = now }
            if now - quietSince! > 1 { hasBeat = false }
        }

        // Phase: the offset whose comb of beats lines up with the most onset energy.
        guard let period else { return }
        let p = period / dt
        var bestPhase = 0, bestComb = -Float.infinity
        for phase in 0..<Int(p) {
            var sum: Float = 0
            var k = 0.0
            while true {
                let i = x.count - 1 - phase - Int((k * p).rounded())
                if i < 1 { break }
                sum += max(x[i - 1], x[i], x[min(i + 1, x.count - 1)])
                k += 1
            }
            if sum > bestComb { bestComb = sum; bestPhase = phase }
        }
        let measuredBeat = times[times.count - 1 - bestPhase]
        if let previous = lastBeat {
            // Keep the beat grid steady: blend small corrections; move the grid
            // only if a different phase is measured 8 times in a row (~2 s), so
            // off-beat hi-hats or a loud snare can't shift it by half a beat.
            let predicted = previous + ((measuredBeat - previous) / period).rounded() * period
            let error = measuredBeat - predicted
            if abs(error) < 0.06 {
                lastBeat = predicted + error * 0.3
                phaseCandidate = nil
            } else if let c = phaseCandidate, abs(remainder(measuredBeat - c.time, period)) < 0.06 {
                if c.count >= 7 { lastBeat = measuredBeat; phaseCandidate = nil }
                else { lastBeat = predicted; phaseCandidate = (measuredBeat, c.count + 1) }
            } else {
                lastBeat = predicted
                phaseCandidate = (measuredBeat, 0)
            }
        } else {
            lastBeat = measuredBeat
        }
    }

    /// Beat times in [start, end) with a 0-1 strength: the onset energy found at
    /// that beat when it has already been heard, 1 for beats still in the future.
    func beats(from start: Double, to end: Double) -> [(time: Double, strength: Double)] {
        guard hasBeat, let period, let lastBeat else { return [] }
        let peak = Double(values.sorted()[Int(Double(values.count) * 0.95)])
        var result: [(Double, Double)] = []
        var t = lastBeat + ((start - lastBeat) / period).rounded(.up) * period
        while t < end {
            var strength = 1.0
            if let last = times.last, t <= last, peak > 0,
               let i = times.firstIndex(where: { $0 >= t - 0.03 }) {
                let window = values[i..<min(values.count, i + 6)] // ±30 ms
                strength = min(1, Double(window.max() ?? 0) / peak)
            }
            result.append((t, strength))
            t += period
        }
        return result
    }

    private var frameDuration: Double? {
        guard times.count > 1 else { return nil }
        return (times.last! - times.first!) / Double(times.count - 1)
    }

    /// Onset envelope minus its local average, so only the peaks remain.
    private func novelty() -> [Float] {
        let n = values.count, half = 10 // ±~110 ms
        var out = [Float](repeating: 0, count: n)
        var running: Float = 0
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { running += values[i]; prefix[i + 1] = running }
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n, i + half + 1)
            let mean = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            out[i] = max(0, values[i] - mean)
        }
        return out
    }
}

/// Picks individual hits (kicks, snares) out of one band's onset values: a local
/// peak that clearly stands above both the band's recent typical level and a
/// share of its recent loudest hits, so the threshold follows the song.
/// Not thread-safe; use from one queue.
final class HitDetector {
    private let sensitivity: Float   // share of the recent peak a hit must reach
    private let minGap: Double       // seconds between two hits
    private var recent: [Float] = []
    private var peak: Float = 0
    private var previous: (time: Double, value: Float)?
    private var beforePrevious: Float = 0
    private var lastHit = -Double.infinity

    init(sensitivity: Float, minGap: Double = 0.12) {
        self.sensitivity = sensitivity
        self.minGap = minGap
    }

    /// Feed one frame; returns the previous frame as a hit (time, 0-1 strength) if it was one.
    func add(time: Double, value: Float) -> (time: Double, strength: Double)? {
        defer {
            beforePrevious = previous?.value ?? 0
            previous = (time, value)
        }
        recent.append(value)
        if recent.count > 86 { recent.removeFirst() } // ~1 s
        peak = max(value, peak * 0.998)              // halves in ~4 s
        guard let p = previous, p.value >= beforePrevious, p.value > value else { return nil }
        let typical = recent.sorted()[recent.count / 2]
        let threshold = max(typical * 2.5, peak * sensitivity)
        guard p.value > threshold, p.time - lastHit >= minGap else { return nil }
        lastHit = p.time
        return (p.time, Double(min(1, (p.value - threshold) / max(peak - threshold, 1e-6))))
    }
}

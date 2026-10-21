import Foundation

/// Listens to the Music app and calls `onPulse` at the moment each pulse should
/// start on the lamps: hit time + speaker delay - lamp delay. Over AirPlay the
/// speakers play ~0.5 s after the Mac, so hits are analysed before they are heard.
/// Two modes: both lamps on the tracked beat, or one lamp per instrument (ceiling
/// on kicks/808s, wall on snares/claps). All state lives on `queue`.
final class Rhythm: @unchecked Sendable {
    enum Mode: String, Sendable { case together, byInstrument }

    struct Pulse: Sendable {
        let strength: Double // 0-1, how hard this beat hits
        let period: Double   // seconds until the next pulse
        let lamp: Int?       // nil: every lamp; else 0 = ceiling, 1 = wall
    }

    struct State: Equatable, Sendable {
        var bpm: Int?
        var hasBeat = false
        var silent = false   // no sound captured for a while (paused, or no recording permission)
        var problem: String?
    }

    /// Both called on the main queue.
    var onPulse: (@MainActor (Pulse) -> Void)?
    var onState: (@MainActor (State) -> Void)?

    /// Time from a command being sent to the lamps visibly changing (measured 50-190 ms, ~100 typical).
    static let lampLead = 0.1
    private static let stalledMessage = "Audio capture didn't start"

    let queue = DispatchQueue(label: "matterglow.rhythm", qos: .userInteractive)
    private lazy var tap = AudioTap(queue: queue)
    private var detector: OnsetDetector?
    private let tracker = BeatTracker()
    private var timer: DispatchSourceTimer?
    private var scheduled: [Double] = []
    private var beatCount = 0
    private var delay = 2.0
    private var lastSound = 0.0
    private var started = 0.0
    private var callbacks = 0
    private var lastUpdate = 0.0
    private var state = State()
    private var recording: Recording?
    private var mode = Mode.together
    private let kicks = HitDetector(sensitivity: 0.3)
    private let snares = HitDetector(sensitivity: 0.45)
    private var lastLampPulse: [Double] = [-.infinity, -.infinity]

    /// A lamp needs ~0.3 s per flash (flash, 180 ms hold, fade), ~3 a second at most.
    private static let lampMinGap = 0.3

    func setDelay(_ seconds: Double) {
        queue.async { self.delay = seconds }
    }

    func setMode(_ mode: Mode) {
        queue.async { self.mode = mode }
    }

    func start(pid: pid_t) {
        queue.async { [self] in
            tap.onSamples = { [weak self] samples, time, rate in self?.receive(samples, time, rate) }
            lastSound = hostSeconds()
            started = lastSound
            callbacks = 0
            do {
                try tap.start(pid: pid)
                publish { $0.problem = nil }
            } catch {
                publish { $0.problem = "\(error)" }
            }
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }
    }

    func stop() {
        queue.async { [self] in
            tap.stop()
            timer?.cancel()
            timer = nil
            publish { $0 = State() }
        }
    }

    /// Start tracking afresh, e.g. when a new song starts.
    func reset() {
        queue.async { self.tracker.reset() }
    }

    /// Calibration: keep the raw tapped audio until `endRecording`.
    func beginRecording() {
        queue.async { self.recording = Recording(start: 0, rate: 0) }
    }

    func endRecording() async -> Recording? {
        await withCheckedContinuation { continuation in
            queue.async {
                let r = self.recording
                self.recording = nil
                continuation.resume(returning: r?.samples.isEmpty == false ? r : nil)
            }
        }
    }

    private func receive(_ samples: [Float], _ time: Double, _ rate: Double) {
        if detector == nil { detector = OnsetDetector(sampleRate: rate) }
        callbacks += 1
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        if peak > 1e-4 { lastSound = time }
        let onsets = detector!.process(samples, at: time)
        tracker.add(onsets)
        for o in onsets { // keep both detectors warm in either mode
            let kick = kicks.add(time: o.time, value: o.bass)
            let snare = snares.add(time: o.time, value: o.snare)
            guard mode == .byInstrument, time - lastSound < 1.5 else { continue }
            if let kick { schedule(kick, lamp: 0) }
            if let snare { schedule(snare, lamp: 1) }
        }
        if recording != nil {
            if recording!.samples.isEmpty { recording = Recording(start: time, rate: rate) }
            recording!.samples += samples
        }
    }

    /// One lamp flashes for one instrument hit, timed for when it is heard.
    private func schedule(_ hit: (time: Double, strength: Double), lamp: Int) {
        let fire = hit.time + delay - Self.lampLead
        guard fire - lastLampPulse[lamp] >= Self.lampMinGap else { return }
        lastLampPulse[lamp] = fire
        let pulse = Pulse(strength: hit.strength, period: tracker.period ?? 0.5, lamp: lamp)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fire - hostSeconds())) { [weak self] in
            MainActor.assumeIsolated { self?.onPulse?(pulse) }
        }
    }

    private func tick() {
        let now = hostSeconds()
        if now - lastUpdate >= 0.25 {
            lastUpdate = now
            tracker.update()
            let silent = now - lastSound > 1.5
            let stalled = callbacks == 0 && now - started > 3
            publish {
                if stalled { $0.problem = Self.stalledMessage } else if $0.problem == Self.stalledMessage { $0.problem = nil }
                $0.silent = silent
                $0.hasBeat = tracker.hasBeat && !silent
                $0.bpm = tracker.bpm.map { Int($0.rounded()) }
            }
        }
        guard mode == .together, state.hasBeat, let period = tracker.period else { return }

        // Schedule the beats whose lamp moment falls in the next 400 ms.
        let offset = delay - Self.lampLead
        let halfTime = period < 0.4 // above 150 BPM pulse every other beat, the lamps can't keep up
        // One pulse per beat: nothing near a beat already sent, nothing out of order.
        let latest = scheduled.max() ?? -.infinity
        for beat in tracker.beats(from: now - offset, to: now - offset + 0.4)
        where beat.time > latest + period * 0.6 {
            scheduled.append(beat.time)
            beatCount += 1
            if halfTime && beatCount % 2 == 0 { continue }
            let pulse = Pulse(strength: beat.strength, period: halfTime ? period * 2 : period, lamp: nil)
            let wait = max(0, beat.time + offset - now)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated { self?.onPulse?(pulse) }
            }
        }
        scheduled.removeAll { $0 < now - offset - 2 }
    }

    private func publish(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onState?(next) }
        }
    }
}

import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            engine.send(["cmd": enabled ? "enable" : "disable"])
            updateRhythm()
        }
    }

    var brightness: Double {
        didSet {
            UserDefaults.standard.set(brightness, forKey: "brightness")
            engine.send(["cmd": "brightness", "value": brightness])
        }
    }

    /// Pulse the lamps on the beat.
    var rhythmEnabled: Bool {
        didSet {
            UserDefaults.standard.set(rhythmEnabled, forKey: "rhythm")
            updateRhythm()
        }
    }

    /// Both lamps on the beat, or ceiling on kicks and wall on snares.
    var pulseMode: Rhythm.Mode {
        didSet {
            UserDefaults.standard.set(pulseMode.rawValue, forKey: "pulseMode")
            rhythm.setMode(pulseMode)
            if enabled { engine.send(["cmd": "steady"]) }
        }
    }

    /// How far the lamps dim between beats (0 = no pulse, 1 = down to almost off).
    var pulseDepth: Double {
        didSet { UserDefaults.standard.set(pulseDepth, forKey: "pulseDepth") }
    }

    /// Manual fine-tuning on top of the measured speaker delay, in seconds.
    var syncTrim: Double {
        didSet {
            UserDefaults.standard.set(syncTrim, forKey: "syncTrim")
            applyDelay()
        }
    }

    private(set) var track: Track?
    private(set) var artwork: NSImage?
    private(set) var isPlaying = false
    private(set) var palette: [RGB] = [.warmWhite]
    /// What each lamp is fading to right now (drift and swaps included), and how long that fade takes.
    private(set) var lampColors: [RGB] = []
    private(set) var lampFade = 1.5
    private(set) var lampsConnected = 0
    private(set) var lampsTotal = 0
    private(set) var problem: String?

    private(set) var rhythmState = Rhythm.State()
    private(set) var rhythmRunning = false
    private(set) var beatCounts = [0, 0] // per lamp, bumps on every pulse; drives the beat dots in the menu
    private(set) var calibrating = false
    private(set) var calibrationMessage: String?
    /// Measured speaker delay for the current output, nil if never calibrated.
    private(set) var speakerDelay: Double?

    @ObservationIgnored private let engine = Engine()
    @ObservationIgnored private let music = MusicWatcher()
    @ObservationIgnored private let rhythm = Rhythm()
    @ObservationIgnored private var delays: [String: Double] // per output device UID
    @ObservationIgnored private var output = defaultOutputDevice()
    @ObservationIgnored private var musicPID: pid_t?
    @ObservationIgnored private var outputTimer: Timer?
    @ObservationIgnored private var lastPulse: [Date] = [.distantPast, .distantPast]

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        brightness = defaults.object(forKey: "brightness") as? Double ?? 0.3
        rhythmEnabled = defaults.object(forKey: "rhythm") as? Bool ?? true
        pulseDepth = defaults.object(forKey: "pulseDepth") as? Double ?? 0.6
        pulseMode = (defaults.string(forKey: "pulseMode")).flatMap(Rhythm.Mode.init) ?? .together
        syncTrim = defaults.object(forKey: "syncTrim") as? Double ?? 0
        delays = defaults.dictionary(forKey: "speakerDelays") as? [String: Double] ?? [:]

        engine.onStart = { [weak self] in self?.syncEngine() }
        engine.onEvent = { [weak self] in self?.handle($0) }
        engine.start()

        music.onTrackChange = { [weak self] track, image, source in
            guard let self else { return }
            self.track = track
            rhythm.reset() // a new song has its own tempo
            artwork = image
            palette = image.map(Palette.extract) ?? [.warmWhite]
            // track/artwork are only for the engine log; the last artwork is kept
            // next to it so a palette that looks wrong can be reproduced.
            engine.send([
                "cmd": "palette", "colors": palette.map(\.bytes),
                "track": "\(track.name) — \(track.artist)",
                "artwork": image.map { "\(Int($0.size.width))px from \(source)" } ?? "none",
            ])
            if let tiff = image?.tiffRepresentation {
                try? tiff.write(to: Engine.logURL.deletingLastPathComponent().appendingPathComponent("last-artwork.tiff"))
            }
        }
        music.onPlayingChange = { [weak self] in self?.isPlaying = $0 }
        music.start()

        rhythm.setMode(pulseMode)
        rhythm.onPulse = { [weak self] in self?.pulse($0) }
        rhythm.onState = { [weak self] in self?.rhythmChanged($0) }
        applyDelay()
        // Follow Music quitting/relaunching (its audio process changes) and output changes.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.Music" else { return }
                MainActor.assumeIsolated { self?.updateRhythm() }
            }
        }
        outputTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOutput() }
        }
        updateRhythm()
    }

    /// Hand the lamps back and stop the engine (used when quitting).
    func shutdown(completion: @escaping @MainActor () -> Void) {
        rhythm.stop()
        engine.stop(completion: completion)
    }

    /// Measure the speaker delay with the microphone (music must be playing).
    func calibrate() {
        guard !calibrating, rhythmRunning else { return }
        calibrating = true
        calibrationMessage = "Listening… keep the music playing"
        Task {
            let result = await Calibrator.measure(with: rhythm)
            calibrating = false
            switch result {
            case .success(let delay):
                calibrationMessage = nil
                if let uid = output?.uid {
                    delays[uid] = delay
                    UserDefaults.standard.set(delays, forKey: "speakerDelays")
                }
                applyDelay()
                log("calibrated speaker delay: \(String(format: "%.3f", delay)) s")
            case .failure(let failure):
                calibrationMessage = failure.description
                log("calibration failed: \(failure)")
            }
        }
    }

    // MARK: - Private

    private func syncEngine() {
        engine.send(["cmd": "brightness", "value": brightness])
        engine.send(["cmd": "palette", "colors": palette.map(\.bytes)])
        if enabled { engine.send(["cmd": "enable"]) }
    }

    private func log(_ message: String) {
        engine.send(["cmd": "log", "message": message])
    }

    /// Run the audio tap only while it's useful, on Music's current process.
    private func updateRhythm() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.processIdentifier
        let wanted = enabled && rhythmEnabled && pid != nil
        if wanted, !rhythmRunning || pid != musicPID {
            rhythm.start(pid: pid!)
            rhythmRunning = true
            musicPID = pid
        } else if !wanted, rhythmRunning {
            rhythm.stop()
            rhythmRunning = false
            musicPID = nil
            if enabled { engine.send(["cmd": "steady"]) }
        }
    }

    private func pulse(_ pulse: Rhythm.Pulse) {
        guard enabled, rhythmEnabled else { return }
        let base = brightness * (1 - pulseDepth)
        // Every beat flashes clearly; the strongest ones up to the full brightness.
        let peak = base + (brightness - base) * (0.8 + 0.2 * pulse.strength)
        // The lamp holds the peak ~180 ms (see sender.js), then fades for half a beat.
        let fade = min(0.5, max(0.15, pulse.period * 0.5))
        var message: [String: Any] = ["cmd": "pulse", "peak": peak, "base": base, "fade": fade * 10]
        if let lamp = pulse.lamp { message["lamp"] = lamp }
        engine.send(message)
        for lamp in pulse.lamp.map({ [$0] }) ?? [0, 1] {
            beatCounts[lamp] &+= 1
            lastPulse[lamp] = .now
        }
        // By instrument, a lamp whose instrument goes quiet (intro, break) goes back
        // to the plain brightness instead of staying dimmed.
        if let lamp = pulse.lamp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.enabled, Date.now.timeIntervalSince(self.lastPulse[lamp]) >= 2.4 else { return }
                    self.engine.send(["cmd": "steady", "lamp": lamp])
                }
            }
        }
    }

    private func rhythmChanged(_ state: Rhythm.State) {
        let old = rhythmState
        rhythmState = state
        if old.hasBeat, !state.hasBeat, enabled { engine.send(["cmd": "steady"]) }
        if old.hasBeat != state.hasBeat || old.silent != state.silent || abs((old.bpm ?? 0) - (state.bpm ?? 0)) >= 3 || old.problem != state.problem {
            log("rhythm: \(state.hasBeat ? "\(state.bpm ?? 0) BPM" : "no beat")\(state.silent ? ", silent" : "")\(state.problem.map { ", \($0)" } ?? "")")
        }
    }

    private func checkOutput() {
        let now = defaultOutputDevice()
        guard now?.uid != output?.uid else { return }
        output = now
        applyDelay()
    }

    /// Speaker delay for the current output (measured, or a guess) plus the trim.
    private func applyDelay() {
        speakerDelay = output.flatMap { delays[$0.uid] }
        let guess = (output?.isAirPlay ?? true) ? 2.0 : (output?.latency ?? 0) + 0.01
        rhythm.setDelay((speakerDelay ?? guess) + syncTrim)
    }

    private func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "status":
            lampsConnected = event["connected"] as? Int ?? 0
            lampsTotal = event["total"] as? Int ?? 0
            problem = lampsConnected < lampsTotal ? "\(lampsTotal - lampsConnected) lamp(s) not answering" : nil
        case "error":
            problem = event["message"] as? String
        case "colors":
            if let lamps = event["lamps"] as? [[Double]] {
                lampFade = event["fade"] as? Double ?? 1.5
                lampColors = lamps.map { RGB(r: $0[0] / 255, g: $0[1] / 255, b: $0[2] / 255) }
            }
        case "restarting":
            problem = "Engine restarting…"
        default:
            break
        }
    }
}

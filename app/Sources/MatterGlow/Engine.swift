import Foundation

/// Runs the Node lamp engine (engine.js, bundled in Resources/engine by
/// scripts/build-app.sh) as a child process and exchanges one JSON object per
/// line with it. Node itself must be installed (see README).
@MainActor
final class Engine {
    var onEvent: (([String: Any]) -> Void)?
    /// Called after every (re)start; the engine starts blank, so send it the full state here.
    var onStart: (() -> Void)?
    var onExit: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopping = false
    private var restarts = 0

    private let engineDir = Bundle.main.resourceURL!.appendingPathComponent("engine").path

    /// The node found when the app was built, else the usual install locations.
    private let nodePath: String = {
        let candidates = [Bundle.main.object(forInfoDictionaryKey: "NodePath") as? String,
                          "/opt/homebrew/bin/node", "/usr/local/bin/node"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"
    }()

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MatterGlow/engine.log")

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nodePath)
        p.arguments = ["engine.js"]
        p.currentDirectoryURL = URL(fileURLWithPath: engineDir)
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Self.openLog()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data means the engine closed stdout; without detaching, the
            // handler would keep firing in a tight loop.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.exited() }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
            onStart?()
        } catch {
            let reason = FileManager.default.isExecutableFile(atPath: nodePath)
                ? error.localizedDescription : "Node.js not found - install it (see README)"
            onEvent?(["event": "error", "message": "Could not start the engine: \(reason)"])
        }
    }

    func send(_ message: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    /// Closing stdin tells the engine to hand the lamps back and exit.
    func stop(completion: @escaping @MainActor () -> Void) {
        guard let process, process.isRunning else { return completion() }
        stopping = true
        onExit = completion
        try? input?.close()
        // Restoring two lamps takes ~2 s; don't let a stuck engine block quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                if self?.process?.isRunning == true { self?.process?.terminate() }
            }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                onEvent?(event)
            }
        }
    }

    private func exited() {
        process = nil
        input = nil
        if stopping {
            onExit?()
            return
        }
        // Crashed: try again a few times, then report it.
        restarts += 1
        guard restarts <= 3 else {
            onEvent?(["event": "error", "message": "The engine keeps stopping - see \(Self.logURL.path)"])
            return
        }
        onEvent?(["event": "restarting"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private static func openLog() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        return handle
    }
}

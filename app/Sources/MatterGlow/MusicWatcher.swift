import AppKit

struct Track: Equatable {
    let id: String
    let name: String
    let artist: String
    let album: String
}

/// Follows what the Music app on this Mac is playing. Music announces every
/// play/pause/track change with a distributed notification; the details and the
/// artwork are then read over Apple Events (needs the Automation permission).
@MainActor
final class MusicWatcher {
    /// The artwork source is "music" or "itunes" (the search fallback), for the log.
    var onTrackChange: ((Track, NSImage?, String) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?

    private var currentID: String?
    private let script = NSAppleScript(source: """
        tell application "Music"
            if player state is stopped then return {"stopped"}
            set t to current track
            set art to missing value
            try
                set art to raw data of artwork 1 of t
            end try
            return {player state as string, persistent ID of t, name of t, artist of t, album of t, art}
        end tell
        """)!

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        // Talking to Music would launch it, so only ask when it is already running.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
            onPlayingChange?(false)
            return
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Music query failed: \(error)")
            return
        }
        guard result.numberOfItems >= 6, let id = result.atIndex(2)?.stringValue else {
            onPlayingChange?(false)
            return
        }
        onPlayingChange?(result.atIndex(1)?.stringValue == "playing")
        guard id != currentID else { return }
        currentID = id

        let track = Track(
            id: id,
            name: result.atIndex(3)?.stringValue ?? "",
            artist: result.atIndex(4)?.stringValue ?? "",
            album: result.atIndex(5)?.stringValue ?? ""
        )
        if let art = result.atIndex(6), art.descriptorType != typeNull, let image = NSImage(data: art.data) {
            onTrackChange?(track, image, "music")
        } else {
            // Apple Music streams don't always expose artwork over Apple Events.
            Task {
                let image = await Self.storeArtwork(for: track)
                if currentID == track.id { onTrackChange?(track, image, "itunes") }
            }
        }
    }

    /// Fallback: look the album up in Apple's public iTunes Search API.
    private static func storeArtwork(for track: Track) async -> NSImage? {
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [
            .init(name: "term", value: "\(track.artist) \(track.album)"),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "1"),
        ]
        struct Response: Decodable {
            struct Item: Decodable { let artworkUrl100: String? }
            let results: [Item]
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let small = (try? JSONDecoder().decode(Response.self, from: data))?.results.first?.artworkUrl100,
              let large = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600")),
              let (imageData, _) = try? await URLSession.shared.data(from: large)
        else { return nil }
        return NSImage(data: imageData)
    }
}

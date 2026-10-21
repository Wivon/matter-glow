import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            header
            nowPlaying
            brightness
            rhythm
            footer
        }
        .padding(12)
        .frame(width: 320)
        .animation(.smooth(duration: 0.3), value: model.rhythmEnabled)
        .animation(.smooth(duration: 0.3), value: model.enabled)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Matter Glow").font(.title3.weight(.semibold))
            Spacer()
            Toggle("Lamps follow the music", isOn: $model.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 4)
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.track?.name ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                    Text(model.track?.artist ?? "Play something in Music")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                lampChips
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glow }
        .background(.fill.quinary, in: platter)
        .clipShape(platter)
    }

    private var brightness: some View {
        section {
            HStack {
                Label("Brightness", systemImage: "sun.max.fill")
                Spacer()
                Text("\(Int((model.brightness * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $model.brightness, in: 0.05...1) {
                Text("Brightness")
            } minimumValueLabel: {
                Image(systemName: "sun.min")
            } maximumValueLabel: {
                Image(systemName: "sun.max")
            }
            .labelsHidden()
        }
        .disabled(!model.enabled)
    }

    private var rhythm: some View {
        section {
            HStack(spacing: 8) {
                Label("Rhythm", systemImage: "metronome.fill")
                if model.rhythmEnabled, !rhythmText.isEmpty {
                    HStack(spacing: 5) {
                        if model.pulseMode == .byInstrument {
                            // One dot per lamp: ceiling (kicks), wall (snares).
                            BeatDot(count: model.beatCounts[0], active: listening)
                            BeatDot(count: model.beatCounts[1], active: listening)
                        } else {
                            BeatDot(count: model.beatCounts[0], active: model.rhythmState.hasBeat)
                        }
                        Text(rhythmText).monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
                    .transition(.opacity)
                }
                Spacer()
                Toggle("Pulse on the beat", isOn: $model.rhythmEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if model.rhythmEnabled {
                Picker("Pulse", selection: $model.pulseMode) {
                    Text("Together").tag(Rhythm.Mode.together)
                    Text("By instrument").tag(Rhythm.Mode.byInstrument)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Together: both lamps on the beat. By instrument: ceiling on kicks and 808s, wall on snares and claps.")
                VStack(spacing: 8) {
                    row("Depth") {
                        Slider(value: $model.pulseDepth, in: 0.2...0.9) { Text("Depth") }
                            .labelsHidden()
                    }
                    row("Sync") {
                        Slider(value: $model.syncTrim, in: -0.3...0.3) { Text("Sync") }
                            .labelsHidden()
                        Text(String(format: "%+.0f ms", model.syncTrim * 1000))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(delayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(model.calibrating ? "Listening…" : "Calibrate", systemImage: "mic.fill") { model.calibrate() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(model.calibrating || !model.rhythmRunning || !model.isPlaying)
                        .help("Measures your speakers' delay with the microphone while music plays")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .disabled(!model.enabled)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.problem == nil && model.lampsConnected > 0 ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Pieces

    @ViewBuilder private var artwork: some View {
        if let artwork = model.artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "music.note")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.tertiary)
        }
    }

    /// Each lamp's live colour as a tinted Liquid Glass capsule.
    private var lampChips: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(zip(lamps, swatches)), id: \.0.name) { lamp, colour in
                    Label(lamp.name, systemImage: lamp.symbol)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.tint(Color(nsColor: colour.nsColor).opacity(model.enabled ? 0.6 : 0.15)), in: .capsule)
                }
            }
        }
        .animation(.easeInOut(duration: model.lampFade), value: swatches)
    }

    /// Soft light from the two lamp colours behind the now-playing card.
    private var glow: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(Color(nsColor: swatches[0].nsColor))
                    .frame(width: proxy.size.width * 0.6)
                    .position(x: proxy.size.width * 0.15, y: proxy.size.height * 0.3)
                Circle()
                    .fill(Color(nsColor: swatches[1].nsColor))
                    .frame(width: proxy.size.width * 0.6)
                    .position(x: proxy.size.width * 0.9, y: proxy.size.height * 0.8)
            }
            .blur(radius: 36)
            .opacity(model.enabled ? 0.4 : 0.1)
            .animation(.easeInOut(duration: model.lampFade), value: swatches)
        }
    }

    private var platter: some Shape {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(14)), isUniform: true)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: platter)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            content()
        }
    }

    // MARK: - Text

    private let lamps = [(name: "Ceiling", symbol: "lamp.ceiling.fill"), (name: "Wall", symbol: "light.panel.fill")]

    private var listening: Bool {
        model.rhythmRunning && model.isPlaying && !model.rhythmState.silent
    }

    private var rhythmText: String {
        if !model.rhythmRunning { return model.enabled ? "Music isn't open" : "" }
        if model.rhythmState.hasBeat, let bpm = model.rhythmState.bpm { return "\(bpm) BPM" }
        return model.isPlaying ? "Listening…" : "Paused"
    }

    private var delayText: String {
        if let message = model.calibrationMessage { return message }
        if model.rhythmRunning, model.isPlaying, model.rhythmState.silent {
            return "No sound captured. Allow Matter Glow in Privacy & Security → Screen & System Audio Recording."
        }
        if let problem = model.rhythmState.problem { return problem }
        if let delay = model.speakerDelay { return String(format: "Speaker delay %.2f s", delay) }
        return "Speaker delay not measured yet"
    }

    /// One colour per lamp: where each lamp is heading, or the cover's colours when off.
    private var swatches: [RGB] {
        let colours = model.enabled && !model.lampColors.isEmpty ? model.lampColors : model.palette
        return (0..<2).map { colours[$0 % colours.count] }
    }

    private var statusText: String {
        if let problem = model.problem { return problem }
        if model.lampsTotal == 0 { return "Connecting to lamps…" }
        return "\(model.lampsConnected) of \(model.lampsTotal) lamps connected"
    }
}

/// Flashes on every pulse sent to the lamps, so you can check the sync by eye.
private struct BeatDot: View {
    let count: Int
    let active: Bool

    var body: some View {
        Circle()
            .fill(active ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(width: 7, height: 7)
            .keyframeAnimator(initialValue: 0.35, trigger: count) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                LinearKeyframe(1.0, duration: 0.02)
                CubicKeyframe(0.35, duration: 0.3)
            }
    }
}

# Matter Glow

Make your Matter colour lamps follow the music playing on your Mac, like HomePod
**Sound Glow** but for the whole room: the lamps take the colours of the album
artwork, drift and trade colours slowly through the song, and pulse in rhythm —
either together on the beat, or one lamp per instrument (kick and 808 on one,
snare and clap on the other).

A small macOS menu bar app (Swift, Liquid Glass UI) listens to the Music app and
drives the lamps directly over Matter through a Node.js engine built on
[matter.js](https://github.com/project-chip/matter.js). The lamps stay paired with
Apple Home: the Mac joins them as a second Matter controller.

Built and tested with two **IKEA KAJPLATS E27 CWS** (colour) bulbs on Matter over
Thread, with two HomePod minis as Thread border routers.

## Features

- **Album colours** — two colours picked from the artwork (the most prominent
  hue and a contrasting one, or two neighbouring hues for single-colour covers),
  kept saturated and pushed away from white so the bulbs don't wash them out.
  Grey and black-and-white covers give warm white.
- **Slow colour movement** — each lamp's colour wanders around its hue and the
  lamps trade colours every 40 s with a smooth crossfade.
- **Rhythm**
  - *Together*: beat tracking (tempo locked per song) pulses both lamps on the beat.
  - *By instrument*: the ceiling lamp flashes on kicks and 808s, the wall lamp on
    snares and claps, reacting to the actual hits.
  - Pulses are timed for when you *hear* the beat: AirPlay plays ~0.5 s after the
    Mac renders the audio, so every hit is analysed before it's heard. A
    **Calibrate** button measures that delay with the microphone.
- **Brightness** control, pulse depth and a manual sync trim.
- **Hands the lamps back**: turning it off restores how Apple Home had them;
  quitting restores Home's colour and brightness and switches them off.

## Requirements

- macOS 27 and Xcode 27 (Swift 6.4) to build.
- [Node.js](https://nodejs.org) 24 or later (the app runs its engine with it).
- Matter colour lights reachable over IP — for Thread lights, an Apple Home hub
  (HomePod, HomePod mini or Apple TV) acting as Thread border router.
- Music playing **in the Music app on this Mac** (to any output, AirPlay included).

## Setup

```bash
git clone https://github.com/Wivon/matter-glow.git
cd matter-glow
npm ci
```

### 1. Pair the lamps

For each lamp, in the **Home** app: long-press the lamp → scroll down → **Turn On
Pairing Mode**. Home shows an 11-digit setup code; within a few minutes run:

```bash
node pair.js 1234-567-8901 ceiling
```

The lamp stays in Apple Home; the Mac is added as a second controller (you can
remove it later from the same screen). Pair the first lamp as the main one
(ceiling: main colour and kicks) and the second as the accent (wall: second colour
and snares). See [`lamps.example.json`](lamps.example.json) for the resulting list.

Check they answer with `node status.js`, and optionally measure them with
`node bench.js` (each lamp alone) or `node bench.js together`.

### 2. Build and install the app

```bash
./scripts/build-app.sh --install
```

This builds `Matter Glow.app` with the engine and the Liquid Glass icon bundled inside, signs it (with your
*Apple Development* certificate if you have one, so permissions survive rebuilds),
copies it to `/Applications` and launches it. Without `--install` it only builds
into `build/`.

### 3. Permissions

On first use macOS asks to let Matter Glow:

| Permission | Why |
|---|---|
| Control **Music** | read the current song and its artwork |
| **System audio recording** | analyse Music's audio for the beat (locally) |
| **Local network** | talk to the lamps |
| **Microphone** (only when you press Calibrate) | measure your speakers' delay |

If rhythm shows "No sound captured", allow Matter Glow in **System Settings →
Privacy & Security → Screen & System Audio Recording → System Audio Recording Only**.

### 4. Calibrate

Play something with a clear beat and press **Calibrate**. It listens for 8 s and
stores the delay per output device. Fine-tune with **Sync** if needed.

## How it works

```
Music.app ──(Apple Events: song + artwork)──┐
          ──(Core Audio process tap)──┐     │
                                      ▼     ▼
                        Matter Glow.app (Swift, menu bar)
                        • colour extraction from the artwork
                        • onset detection, beat tracking, kick/snare detection
                        • pulse scheduling: hit time + speaker delay − lamp delay
                                      │ JSON lines over stdin/stdout
                                      ▼
                        engine.js (Node, matter.js)
                        • rate-limited, latest-wins sender per lamp
                        • colour drift and swaps (the bulbs fade between targets)
                                      │ Matter over IPv6 → Thread border router
                                      ▼
                                 lamps (Thread)
```

Measured on the KAJPLATS bulbs, and baked into the timing:

- **~50 ms** command round trip; the light changes **50–190 ms** after a command
  (~100 ms typical), so pulses are sent 100 ms early.
- Clean up to **~8 commands/s per lamp** with two lamps busy (16 total). Above
  that commands queue and the Thread network takes up to a minute to recover, so
  the sender never queues: one command in flight per lamp, ≤ 6/s, newer values
  replace unsent ones.
- A command arriving before the previous one has been applied **cancels it**, so a
  pulse holds its flash 180 ms before fading.
- Brightness pulses **don't** interrupt colour fades, so colour movement costs one
  command every few seconds.

## Command-line tools

| Command | What it does |
|---|---|
| `node pair.js <code> <name>` | pair a lamp put in pairing mode by Apple Home |
| `node status.js` | show each paired lamp and its state |
| `node bench.js [together]` | measure latency and the highest safe command rate |

They share the app's controller identity, so quit the app before using them (they
refuse to run while it's open).

## Data and privacy

- Pairing data lives in `~/Library/Application Support/Matter Glow/`:
  `matter-storage/` holds the Mac's Matter controller keys (keep it private),
  `lamps.json` the paired lamps. Set `MATTER_GLOW_DATA` to use another folder.
- Audio is analysed on the Mac and never recorded or sent anywhere. Calibration
  keeps 8 s of microphone audio in memory only.
- If Music doesn't expose a streamed song's artwork, the app looks the album up in
  Apple's public iTunes Search API (artist and album name only).
- Logs: `~/Library/Logs/MatterGlow/engine.log`.

## Known limitations

- Songs that open with a beat-less intro (piano, vocals) can get a wrong tempo in
  *Together* mode until the drums settle it. *By instrument* doesn't depend on the
  tempo.
- Bulbs can't follow hi-hats (8+ hits/s): the wall lamp takes the snare instead.
- Only the Music app on this Mac is followed, not playback started on other devices.

## Project layout

```
app/          Swift package for the menu bar app
  AppIcon.icon          app icon (Icon Composer), compiled by build-app.sh
  Sources/MatterGlow/
    AppModel.swift      state, settings, wiring
    MenuView.swift      the menu (Liquid Glass)
    MusicWatcher.swift  current song and artwork from Music
    Palette.swift       colours from the artwork
    AudioTap.swift      Core Audio process tap on Music
    Beats.swift         onsets, beat tracker, kick/snare hit detectors
    Rhythm.swift        pulse scheduling
    Calibrator.swift    speaker delay via the microphone (GCC-PHAT)
    Engine.swift        runs and talks to engine.js
engine.js     lamp engine (stdin/stdout protocol documented at the top)
lib/          controller, lamps, sender, colours, snapshots, paths
pair.js, status.js, bench.js
scripts/build-app.sh
```

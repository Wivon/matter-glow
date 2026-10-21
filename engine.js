// Lamp engine, driven by the menu bar app over stdin/stdout (one JSON object per line).
//
// In:  {"cmd":"enable"}                      take over the lamps
//      {"cmd":"disable"}                     hand them back as they were
//      (closing stdin)                       hand them back switched off, then exit
//      {"cmd":"palette","colors":[[r,g,b]]}  sRGB 0-255; lamp i gets colors[i % n]
//      {"cmd":"brightness","value":0.3}      0-1
//      {"cmd":"pulse","peak":0.3,"base":0.12,"fade":4,"lamp":0}  flash to peak, fade to base (tenths of s);
//                                            lamp = index in lamps.json, omitted = every lamp
//      {"cmd":"steady","lamp":0}             back to the plain brightness (no beat)
//      {"cmd":"log","message":"..."}         write a line to the engine log
// Out: {"event":"status","connected":2,"total":2,"enabled":true}
//      {"event":"error","message":"..."}
//      {"event":"colors","lamps":[[r,g,b],...]}  colour each lamp is heading to
import { createInterface } from "node:readline";

// stdout carries the protocol; matter.js logs through console, so send all of it to stderr.
for (const k of ["log", "info", "debug", "warn"]) console[k] = console.error;

const { startController } = await import("./lib/controller.js");
const { connectLamps } = await import("./lib/lamp-control.js");
const { LampSender } = await import("./lib/sender.js");
const { lampXy, shiftHue, saturation } = await import("./lib/color.js");
const { snapshot, restore, loadSaved, storeSaved, clearSaved } = await import("./lib/snapshot.js");
const { loadLamps } = await import("./lib/lamps.js");

const MAX_RATE = 6; // commands/s per lamp; 8/s was the clean limit with both lamps busy
const COLOR_FADE = 15; // tenths of a second, on song change
const BRIGHTNESS_FADE = 3;

// Slow colour movement, like HomePod Sound Glow: each lamp's colour wanders
// around its hue and the lamps trade colours now and then. The bulbs fade
// between targets themselves (beat pulses don't interrupt colour fades), so
// this costs one command every few seconds.
const DRIFT_DEGREES = 22;       // how far a colour wanders either side of its hue
const DRIFT_PERIODS = [47, 61]; // seconds per wander, per lamp, so they never move in lockstep
const DRIFT_STEP = 5;           // seconds between targets
const SWAP_EVERY = 40;          // seconds between the lamps trading colours
const SWAP_FADE = 6;            // seconds the trade takes

const emit = obj => process.stdout.write(JSON.stringify(obj) + "\n");
process.stdout.on("error", () => {}); // app gone (EPIPE): keep going so the lamps still get restored
const log = msg => console.error(`${new Date().toISOString()} ${msg}`);
const state = { wanted: false, enabled: false, brightness: 0.3, palette: [[255, 190, 130]] };
let controller, lamps = [], senders = [], saved = {};
let anim = { start: 0, swapped: false, nextSwap: 0, nextStep: 0 };
let lastError = 0;

function report(message) {
    console.error(message);
    if (Date.now() - lastError > 5000) emit({ event: "error", message });
    lastError = Date.now();
}

function status() {
    const s = { event: "status", connected: lamps.length, total: Object.keys(loadLamps()).length, enabled: state.enabled };
    log(`-> ${JSON.stringify(s)}`);
    emit(s);
}

// Pulses per lamp, logged every 30 s so the rhythm can be checked from the log.
let pulseCounts = {};
setInterval(() => {
    const counts = Object.entries(pulseCounts);
    if (counts.length) log(`pulses in the last 30 s: ${counts.map(([n, c]) => `${n} ${c}`).join(", ")}`);
    pulseCounts = {};
}, 30000);

function newSenders() {
    senders = lamps.map(lamp => {
        const s = new LampSender(lamp, { maxRate: MAX_RATE });
        s.name = lamp.name;
        s.onError = e => report(`${lamp.name}: ${e.message}`);
        return s;
    });
}

const seconds = () => performance.now() / 1000;

// Colour lamp i should show at time t (seconds since the song's colours arrived).
function colourAt(i, t) {
    const { palette } = state;
    const base = palette[(i + (anim.swapped ? 1 : 0)) % palette.length];
    if (saturation(base) < 0.5) return base; // whites and pastels (incl. the warm-white fallback) stay put
    const period = DRIFT_PERIODS[i % DRIFT_PERIODS.length];
    return shiftHue(base, DRIFT_DEGREES * Math.sin((2 * Math.PI * t) / period + i * Math.PI / 2));
}

// Send every lamp the colour it should reach `transition` tenths from now.
// Senders for one lamp (its index in lamps.json, so a lamp that didn't connect
// doesn't shift the others) or for all of them.
function sendersFor(index) {
    if (index === undefined) return senders;
    const name = Object.keys(loadLamps())[index];
    return senders.filter((_, i) => lamps[i].name === name);
}

function applyColor(transition) {
    if (!state.enabled) return;
    const t = seconds() - anim.start + transition / 10;
    const colours = senders.map((s, i) => {
        const c = colourAt(i, t);
        s.color(lampXy(c), transition);
        return c;
    });
    emit({ event: "colors", lamps: colours, fade: transition / 10 });
}

function restartAnimation() {
    const now = seconds();
    anim = { start: now, swapped: false, nextSwap: now + SWAP_EVERY, nextStep: now + COLOR_FADE / 10 };
}

setInterval(() => {
    if (!state.enabled) return;
    const now = seconds();
    if (now >= anim.nextSwap && state.palette.length > 1) {
        anim.swapped = !anim.swapped;
        anim.nextSwap = now + SWAP_EVERY;
        log("colours: lamps trade colours");
        anim.nextStep = now + SWAP_FADE;
        applyColor(SWAP_FADE * 10);
    } else if (now >= anim.nextStep) {
        anim.nextStep = now + DRIFT_STEP;
        applyColor(DRIFT_STEP * 10);
    }
}, 500);

function applyLevel(transition) {
    if (!state.enabled) return;
    senders.forEach(s => s.level(state.brightness, transition));
}

// Commands are handled one at a time, so enable/disable never overlap.
let chain = Promise.resolve();
const serial = fn => (chain = chain.then(fn).catch(e => report(e.message)));

async function enable() {
    state.wanted = true;
    if (state.enabled || lamps.length === 0) return;
    // A snapshot left on disk means the last engine died while in control: the
    // lamps now show song colours, so keep Home's settings from back then.
    const previous = loadSaved() ?? {};
    saved = Object.fromEntries(await Promise.all(lamps.map(async l => [l.name, previous[l.name] ?? (await snapshot(l))])));
    storeSaved(saved);
    log(`saved lamp state${Object.keys(previous).length ? " (from the last session)" : ""}: ${JSON.stringify(saved)}`);
    newSenders();
    state.enabled = true;
    restartAnimation();
    applyColor(0); // set while still off/old, so the fade-in is already the right colour
    applyLevel(10);
    status();
}

async function disable({ off = false } = {}) {
    state.wanted = false;
    if (!state.enabled) return;
    state.enabled = false;
    await Promise.all(senders.map(s => s.stop()));
    await Promise.all(lamps.map(lamp => restore(lamp, saved[lamp.name], { off }).catch(e => report(`${lamp.name}: ${e.message}`))));
    const after = await Promise.all(lamps.map(async l => [l.name, await snapshot(l).catch(() => null)]));
    log(`handed lamps back${off ? " switched off" : ""}: ${JSON.stringify(Object.fromEntries(after))}`);
    clearSaved();
    status();
}

const handlers = {
    enable: () => serial(enable),
    disable: () => serial(() => disable()),
    palette: ({ colors }) => {
        if (Array.isArray(colors) && colors.length) state.palette = colors;
        restartAnimation();
        applyColor(COLOR_FADE);
    },
    brightness: ({ value }) => {
        state.brightness = Math.min(1, Math.max(0.01, Number(value)));
        applyLevel(BRIGHTNESS_FADE);
    },
    pulse: ({ peak, base, fade, lamp }) => {
        if (!state.enabled) return;
        for (const s of sendersFor(lamp)) {
            s.pulse(Number(peak), Number(base), Math.max(1, Math.round(fade)));
            pulseCounts[s.name] = (pulseCounts[s.name] ?? 0) + 1;
        }
    },
    steady: ({ lamp }) => {
        if (state.enabled) sendersFor(lamp).forEach(s => s.level(state.brightness, 5));
    },
    log: ({ message }) => log(String(message)),
};

let shuttingDown = false;
async function shutdown() {
    if (shuttingDown) return;
    shuttingDown = true;
    await serial(() => disable({ off: true }));
    await controller?.close();
    process.exit(0);
}

createInterface({ input: process.stdin })
    .on("line", line => {
        try {
            const msg = JSON.parse(line);
            if (!["brightness", "pulse", "steady", "log"].includes(msg.cmd)) log(`<- ${line}`); // too chatty to log
            handlers[msg.cmd]?.(msg);
        } catch (e) {
            report(`bad command: ${line}`);
        }
    })
    .on("close", shutdown); // the app quit or closed the pipe
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

// matter.js would close everything on SIGTERM itself, aborting the restore above.
controller = await startController({ logLevel: "error", trapSignals: false });
lamps = await connectLamps(controller, { timeoutMs: 20000 });
for (const name of Object.keys(loadLamps())) {
    if (!lamps.some(l => l.name === name)) report(`${name} did not answer`);
}
status();
if (state.wanted) serial(enable);

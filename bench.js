// Measure command latency and the highest command rate the lamps keep up with.
// Usage: node bench.js            each lamp on its own
//        node bench.js together   all lamps at once (they share the Thread network)
import { startController } from "./lib/controller.js";
import { connectLamps, setColor, setLevel } from "./lib/lamp-control.js";
import { snapshot, restore } from "./lib/snapshot.js";

const controller = await startController();
const lamps = await connectLamps(controller);
if (lamps.length === 0) {
    console.error("No lamps in lamps.json - pair one first.");
    process.exit(1);
}

const wait = ms => new Promise(r => setTimeout(r, ms));
const pct = (xs, p) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(p * xs.length))];
const fmt = xs => (xs.length ? `median ${pct(xs, 0.5).toFixed(0)} ms, p95 ${pct(xs, 0.95).toFixed(0)} ms, max ${Math.max(...xs).toFixed(0)} ms` : "no replies");

async function timed(promiseFn) {
    const t = performance.now();
    await promiseFn();
    return performance.now() - t;
}

const saved = await Promise.all(lamps.map(async lamp => ({ lamp, state: await snapshot(lamp) })));

if (process.argv[2] === "together") {
    console.log(`\n=== ${lamps.map(l => l.name).join(" + ")} together ===`);
    await Promise.all(lamps.map(l => setLevel(l, 0.7)));

    // Send the same colour to every lamp at the same instant. "skew" is how far
    // apart the lamps confirm it, i.e. how out of step they would look.
    for (const rate of [2, 4, 6, 8, 10, 12]) {
        const rtts = [], skews = [], failures = [];
        const pending = [];
        const n = rate * 5;
        for (let i = 0; i < n; i++) {
            const t = performance.now();
            pending.push(
                Promise.all(
                    lamps.map(l =>
                        setColor(l, (i * 137) % 360, 1).then(() => {
                            const rtt = performance.now() - t;
                            rtts.push([i, rtt]);
                            return rtt;
                        }),
                    ),
                )
                    .then(r => skews.push(Math.max(...r) - Math.min(...r)))
                    .catch(e => failures.push(e.message)),
            );
            await wait(1000 / rate);
        }
        await Promise.allSettled(pending);
        const all = rtts.map(([, v]) => v);
        const firstQ = rtts.filter(([i]) => i < n / 4).map(([, v]) => v);
        const lastQ = rtts.filter(([i]) => i >= (3 * n) / 4).map(([, v]) => v);
        const drift = firstQ.length && lastQ.length ? pct(lastQ, 0.5) - pct(firstQ, 0.5) : NaN;
        console.log(
            `${String(rate).padStart(2)}/s per lamp: ${all.length}/${n * lamps.length} ok, ${fmt(all)}, drift ${drift.toFixed(0)} ms, ` +
                `skew median ${skews.length ? pct(skews, 0.5).toFixed(0) : "-"} ms / p95 ${skews.length ? pct(skews, 0.95).toFixed(0) : "-"} ms` +
                (failures.length ? `, ${failures.length} failed (${failures[0]})` : ""),
        );
        if (failures.length > n / 4 || pct(all, 0.5) > 1000) break;
        await wait(1500);
    }
} else {
    for (const lamp of lamps) {
        console.log(`\n=== ${lamp.name} (${lamp.hasHueSat ? "hue/sat" : "xy"} colour) ===`);
        await setLevel(lamp, 0.7);

        // 1. Latency at a calm pace: one command at a time.
        const calm = [];
        for (let i = 0; i < 25; i++) {
            calm.push(await timed(() => setColor(lamp, (i * 137) % 360, 1)));
            await wait(500);
        }
        console.log(`Latency (1 command at a time): ${fmt(calm)}`);

        // 2. Ramp the rate. Commands are fired without waiting; if replies get slower
        //    over the run, the lamp/network is queueing and that rate is too high.
        for (const rate of [2, 4, 6, 8, 12, 16, 24]) {
            const rtts = [], failures = [];
            const pending = [];
            const n = rate * 5;
            for (let i = 0; i < n; i++) {
                const t = performance.now();
                pending.push(
                    setColor(lamp, (i * 137) % 360, 1)
                        .then(() => rtts.push([i, performance.now() - t]))
                        .catch(e => failures.push(e.message)),
                );
                await wait(1000 / rate);
            }
            await Promise.allSettled(pending);
            const all = rtts.map(([, v]) => v);
            const firstQ = rtts.filter(([i]) => i < n / 4).map(([, v]) => v);
            const lastQ = rtts.filter(([i]) => i >= (3 * n) / 4).map(([, v]) => v);
            const drift = firstQ.length && lastQ.length ? pct(lastQ, 0.5) - pct(firstQ, 0.5) : NaN;
            console.log(
                `${String(rate).padStart(2)}/s: ${all.length}/${n} ok, ${fmt(all)}, drift ${drift.toFixed(0)} ms` +
                    (failures.length ? `, ${failures.length} failed (${failures[0]})` : ""),
            );
            if (failures.length > n / 4 || pct(all, 0.5) > 1000) break;
            await wait(1500);
        }
    }
}

// Put the lamps back the way they were.
for (const { lamp, state } of saved) {
    await restore(lamp, state, { transitionTime: 0 }).catch(e => console.warn(`Could not restore ${lamp.name}: ${e.message}`));
}
await controller.close();
process.exit(0);

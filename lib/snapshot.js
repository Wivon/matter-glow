// Remember how a lamp was set (e.g. by Apple Home) and put it back later.
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { snapshotFile as file } from "./paths.js";

const options = { optionsMask: { executeIfOff: true }, optionsOverride: { executeIfOff: true } };
const wait = ms => new Promise(r => setTimeout(r, ms));

export async function snapshot(lamp) {
    const c = lamp.color;
    return {
        on: await lamp.onOff.getOnOffAttribute(true),
        level: await lamp.level.getCurrentLevelAttribute(true),
        mode: await c.getColorModeAttribute(true),
        mireds: await c.getColorTemperatureMiredsAttribute?.(true),
        x: await c.getCurrentXAttribute?.(true),
        y: await c.getCurrentYAttribute?.(true),
    };
}

// off: switch the lamp off even if it was on before (used when quitting).
export async function restore(lamp, s, { off = false, transitionTime = 10 } = {}) {
    const c = lamp.color;
    const colourAndLevel = async transitionTime => {
        if (s.mode === 2 && s.mireds) await c.moveToColorTemperature({ colorTemperatureMireds: s.mireds, transitionTime, ...options });
        else if (s.x !== undefined) await c.moveToColor({ colorX: s.x, colorY: s.y, transitionTime, ...options });
        if (s.level) await lamp.level.moveToLevel({ level: s.level, transitionTime, ...options });
    };
    if (off || s.on === false) {
        // Switch off first, then put the colour and brightness back while dark (the
        // bulbs accept that), so there is no flash now and Home's next "on" looks
        // normal. Changes sent during the off fade get dropped, hence the wait.
        await lamp.onOff.off();
        await wait(1000);
        await colourAndLevel(0);
    } else {
        await colourAndLevel(transitionTime);
    }
}

// The snapshot is also kept on disk while the app is in control, so an engine
// that restarts (or crashed) restores Home's settings, not the song colours.
export function loadSaved() {
    try {
        return JSON.parse(readFileSync(file, "utf8"));
    } catch {
        return undefined;
    }
}

export function storeSaved(saved) {
    writeFileSync(file, JSON.stringify(saved, null, 2));
}

export function clearSaved() {
    rmSync(file, { force: true });
}

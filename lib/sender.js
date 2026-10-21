// Sends the latest wanted state to one lamp, never a backlog. The bench showed
// that queued commands collapse the Thread network (24/s took a minute to
// recover), so: one command in flight per lamp, an average rate limit (with a
// small burst so a pulse's flash and fade can go out back to back), and a newer
// value simply replaces one that has not been sent yet.
//
// The bulbs apply a command 50-190 ms after receiving it, and a newer command
// arriving before that cancels it. So a pulse's fade waits FLASH_HOLD_MS after
// its flash, or the flash never shows (measured: 100 ms failed, 150+ never did).
const FLASH_HOLD_MS = 180;
const options = { optionsMask: { executeIfOff: true }, optionsOverride: { executeIfOff: true } };
const toLevel = v => Math.max(1, Math.min(254, Math.round(v * 254)));

export class LampSender {
    #lamp;
    #rate;
    #burst = 3;
    #tokens = 3;
    #refilled = performance.now();
    #pending = {}; // flash, level: {level, transition, afterFlash}; color: {xy, transition}
    #flashSentAt = 0;
    #busy = false;
    #stopped = false;
    onError = () => {};

    constructor(lamp, { maxRate = 6 } = {}) {
        this.#lamp = lamp;
        this.#rate = maxRate;
    }

    // xy: Matter-scaled [x, y]; transition in tenths of a second.
    color(xy, transition = 0) {
        this.#pending.color = { xy, transition };
        this.#pump();
    }

    // level: 0-1, turns the lamp on if needed.
    level(level, transition = 0) {
        delete this.#pending.flash;
        this.#pending.level = { level: toLevel(level), transition };
        this.#pump();
    }

    // Jump to `peak` at once, then fade to `base` over `fade` tenths of a second.
    pulse(peak, base, fade) {
        this.#pending.flash = { level: toLevel(peak), transition: 0 };
        this.#pending.level = { level: toLevel(base), transition: fade, afterFlash: true };
        this.#pump();
    }

    // Drop anything not yet sent and wait for the command in flight.
    async stop() {
        this.#stopped = true;
        this.#pending = {};
        while (this.#busy) await new Promise(r => setTimeout(r, 20));
    }

    // Milliseconds until a send is allowed (0 = now, and the token is taken).
    #takeToken() {
        const now = performance.now();
        this.#tokens = Math.min(this.#burst, this.#tokens + ((now - this.#refilled) / 1000) * this.#rate);
        this.#refilled = now;
        if (this.#tokens >= 1) {
            this.#tokens -= 1;
            return 0;
        }
        return ((1 - this.#tokens) / this.#rate) * 1000;
    }

    async #pump() {
        if (this.#busy || this.#stopped) return;
        // The flash goes first and its fade right after; colours fit in between beats.
        const key = ["flash", "level", "color"].find(k => this.#pending[k]);
        if (!key) return;

        this.#busy = true;
        if (key === "level" && this.#pending.level.afterFlash) {
            const hold = this.#flashSentAt + FLASH_HOLD_MS - performance.now();
            if (hold > 0) await new Promise(r => setTimeout(r, hold));
        }
        for (let wait; (wait = this.#takeToken()) > 0; ) await new Promise(r => setTimeout(r, wait));
        const name = ["flash", "level", "color"].find(k => this.#pending[k]); // may have changed while waiting
        const job = name && this.#pending[name];
        if (name) delete this.#pending[name];
        try {
            if (!job || this.#stopped) return;
            if (name === "flash") this.#flashSentAt = performance.now();
            if (name === "color") {
                await this.#lamp.color.moveToColor({ colorX: job.xy[0], colorY: job.xy[1], transitionTime: job.transition, ...options });
            } else {
                await this.#lamp.level.moveToLevelWithOnOff({ level: job.level, transitionTime: job.transition, ...options });
            }
        } catch (e) {
            this.onError(e);
        } finally {
            this.#busy = false;
            this.#pump();
        }
    }
}

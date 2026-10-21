// Shared Matter controller setup. The Mac joins the lamps as a second admin
// (multi-admin), so they stay paired with Apple Home as well.
import { Environment, Logger } from "@matter/main";
import { CommissioningController } from "@project-chip/matter.js";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { lockFile, storageDir } from "./paths.js";

export async function startController({ autoConnect = false, logLevel = "warn", trapSignals = true } = {}) {
    lock();
    Logger.level = logLevel;
    const environment = Environment.default;
    environment.vars.set("storage.path", storageDir);
    environment.vars.set("runtime.signals", trapSignals);

    const controller = new CommissioningController({
        environment: { environment, id: "matter-glow" },
        autoConnect,
        adminFabricLabel: "matter-glow",
    });
    await controller.start();
    return controller;
}

// Connect a paired node and wait until its attributes are read. Awaiting the
// event alone hangs if it already fired (e.g. right after commissioning).
export async function connectNode(controller, nodeId) {
    const node = await controller.getNode(nodeId);
    node.connect();
    if (!node.remoteInitializationDone) await node.events.initializedFromRemote;
    return node;
}

// Two controllers sharing one Matter identity fight over the lamp sessions, so
// only one process (the app's engine or a CLI script) may run at a time.
function lock() {
    try {
        const pid = Number(readFileSync(lockFile, "utf8"));
        process.kill(pid, 0);
        throw new Error(`Another controller is already running (pid ${pid}). Quit the Matter Glow app first.`);
    } catch (e) {
        if (e.code !== "ENOENT" && e.code !== "ESRCH") throw e;
    }
    writeFileSync(lockFile, String(process.pid));
    process.on("exit", () => rmSync(lockFile, { force: true }));
}

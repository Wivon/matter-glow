// Where the pairing data and lamp list live, shared by the menu bar app's engine
// and the command-line tools. Override with MATTER_GLOW_DATA.
// matter-storage holds the Mac's Matter controller keys: keep it private.
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const dataDir = process.env.MATTER_GLOW_DATA ?? join(homedir(), "Library", "Application Support", "Matter Glow");
mkdirSync(dataDir, { recursive: true });

export const storageDir = join(dataDir, "matter-storage");
export const lampsFile = join(dataDir, "lamps.json");
export const snapshotFile = join(dataDir, "snapshot.json");
export const lockFile = join(dataDir, "controller.lock");

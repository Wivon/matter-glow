// lamps.json maps a friendly name to the paired Matter node and its light endpoint.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { lampsFile as file } from "./paths.js";

export function loadLamps() {
    return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
}

export function saveLamp(name, lamp) {
    writeFileSync(file, JSON.stringify({ ...loadLamps(), [name]: lamp }, null, 2) + "\n");
}

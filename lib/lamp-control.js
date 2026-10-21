// Connect to the paired lamps and expose a minimal "set colour" API.
import { OnOff, LevelControl, ColorControl } from "@matter/main/clusters";
import { NodeId } from "@matter/main/types";
import { loadLamps } from "./lamps.js";
import { connectNode } from "./controller.js";
import { rgbToXy } from "./color.js";

const options = { optionsMask: { executeIfOff: true }, optionsOverride: { executeIfOff: true } };

// Lamps that do not answer within timeoutMs (e.g. switched off at the wall) are
// left out; matter.js keeps trying to reach them in the background.
export async function connectLamps(controller, { timeoutMs = 60000 } = {}) {
    const timeout = () => new Promise(resolve => setTimeout(resolve, timeoutMs));
    const lamps = await Promise.all(
        Object.entries(loadLamps()).map(([name, { nodeId, endpoint }]) =>
            Promise.race([connectNode(controller, NodeId(BigInt(nodeId))), timeout()]).then(node => {
                if (!node) return undefined;
                const device = node.getDeviceById(endpoint);
                const color = device.getClusterClient(ColorControl.Cluster);
                return {
                    name,
                    onOff: device.getClusterClient(OnOff.Cluster),
                    level: device.getClusterClient(LevelControl.Cluster),
                    color,
                    hasHueSat: !!color.supportedFeatures.hueSaturation,
                };
            }),
        ),
    );
    return lamps.filter(Boolean);
}

// hue 0-360, sat 0-1. transition in tenths of a second (Matter's unit).
export function setColor(lamp, hue, sat, transitionTime = 0) {
    if (lamp.hasHueSat) {
        return lamp.color.moveToHueAndSaturation({
            hue: Math.round((hue / 360) * 254),
            saturation: Math.round(sat * 254),
            transitionTime,
            ...options,
        });
    }
    const [x, y] = hueSatToXy(hue, sat);
    return lamp.color.moveToColor({ colorX: x, colorY: y, transitionTime, ...options });
}

// level 0-1
export function setLevel(lamp, level, transitionTime = 0) {
    return lamp.level.moveToLevelWithOnOff({
        level: Math.max(1, Math.round(level * 254)),
        transitionTime,
        ...options,
    });
}

// Hue/saturation at full value -> sRGB -> xy.
function hueSatToXy(hue, sat) {
    const c = sat, h = hue / 60, x = c * (1 - Math.abs((h % 2) - 1)), m = 1 - c;
    const [r, g, b] = h < 1 ? [c, x, 0] : h < 2 ? [x, c, 0] : h < 3 ? [0, c, x] : h < 4 ? [0, x, c] : h < 5 ? [x, 0, c] : [c, 0, x];
    return rgbToXy([r + m, g + m, b + m].map(v => v * 255));
}

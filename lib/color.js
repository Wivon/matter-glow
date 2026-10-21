// sRGB (0-255) -> CIE xy scaled to Matter's 0-65279 range. Using xy rather than
// the bulb's own hue/saturation keeps artwork colours device-independent.
export function rgbToXy(rgb) {
    const [x, y] = rawXy(rgb);
    return [Math.round(x * 65279), Math.round(y * 65279)];
}

// Same, but pushed further from white for the lamps: the bulbs show sRGB colours
// washed out (even pure cyan sits close to white in xy), so chromatic colours are
// moved 40% further out along their hue line, up to a typical RGB-LED gamut (the
// KAJPLATS bulbs don't report theirs). Whites and pastels are left as they are.
const WHITE = [0.3127, 0.329]; // D65
const GAMUT = [[0.6915, 0.3083], [0.17, 0.7], [0.1532, 0.0475]]; // red, green, blue primaries
const PUSH = 1.4;

export function lampXy(rgb) {
    let [x, y] = rawXy(rgb);
    if (saturation(rgb) >= 0.5) {
        [x, y] = [WHITE[0] + (x - WHITE[0]) * PUSH, WHITE[1] + (y - WHITE[1]) * PUSH];
        [x, y] = clampToGamut(x, y);
    }
    return [Math.round(x * 65279), Math.round(y * 65279)];
}

// If (x, y) lies outside the gamut triangle, pull it back towards white onto the edge.
function clampToGamut(x, y) {
    let t = 1; // fraction of the way from white to (x, y) that stays inside
    for (let i = 0; i < 3; i++) {
        const [ax, ay] = GAMUT[i], [bx, by] = GAMUT[(i + 1) % 3];
        // Intersect white + s*(d) with edge a + u*(b - a).
        const dx = x - WHITE[0], dy = y - WHITE[1], ex = bx - ax, ey = by - ay;
        const den = dx * ey - dy * ex;
        if (Math.abs(den) < 1e-12) continue;
        const s = ((ax - WHITE[0]) * ey - (ay - WHITE[1]) * ex) / den;
        const u = ((ax - WHITE[0]) * dy - (ay - WHITE[1]) * dx) / den;
        if (s > 0 && u >= 0 && u <= 1) t = Math.min(t, s);
    }
    return [WHITE[0] + (x - WHITE[0]) * t, WHITE[1] + (y - WHITE[1]) * t];
}

function rawXy([r8, g8, b8]) {
    const lin = v => (v > 0.04045 ? ((v + 0.055) / 1.055) ** 2.4 : v / 12.92);
    const [r, g, b] = [r8, g8, b8].map(v => lin(v / 255));
    const X = r * 0.4124 + g * 0.3576 + b * 0.1805;
    const Y = r * 0.2126 + g * 0.7152 + b * 0.0722;
    const Z = r * 0.0193 + g * 0.1192 + b * 0.9505;
    const sum = X + Y + Z || 1;
    return [X / sum, Y / sum];
}

// Rotate an sRGB colour's hue by `degrees`, keeping saturation and value.
export function shiftHue([r, g, b], degrees) {
    const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    if (d === 0) return [r, g, b];
    let h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    h = (((h * 60 + degrees) % 360) + 360) % 360;
    const s = d / max, v = max / 255;
    const c = v * s, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = v - c;
    const [r1, g1, b1] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    return [r1 + m, g1 + m, b1 + m].map(v => Math.round(v * 255));
}

export function saturation([r, g, b]) {
    const max = Math.max(r, g, b);
    return max === 0 ? 0 : (max - Math.min(r, g, b)) / max;
}

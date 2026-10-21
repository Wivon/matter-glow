import AppKit

/// sRGB colour, components 0-1.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    static let warmWhite = RGB(r: 1, g: 0.76, b: 0.54)

    var bytes: [Int] { [r, g, b].map { Int(($0 * 255).rounded()) } }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    var hsv: (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        var h = 0.0
        if d > 0 {
            if maxC == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : d / maxC, maxC)
    }

    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    init(h: Double, s: Double, v: Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
    }
}

enum Palette {
    /// Two colours that represent the artwork as light: the most prominent hue,
    /// then the strongest hue clearly different from it (a red hurricane on a big
    /// blue background), else a neighbouring hue that is really in the cover, else
    /// the one hue split in two (a dark teal cover gives teal-green and blue).
    /// Covers with no real colour (black and white, grey) give warm white.
    static func extract(from image: NSImage) -> [RGB] {
        guard let pixels = downsample(image) else { return [.warmWhite] }

        let bins = 36 // 10° of hue each
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bins)
        for c in pixels {
            let (h, s, v) = c.hsv
            // Weigh by chroma (how far from grey), with no brightness cut-off, so a
            // dark but clearly tinted cover still counts. The tiny chroma of
            // near-black compression noise is ignored.
            let chroma = s * v
            guard chroma > 0.02 else { continue }
            let bin = Int(h * Double(bins)) % bins
            weight[bin] += chroma
            sums[bin].r += c.r * chroma; sums[bin].g += c.g * chroma; sums[bin].b += c.b * chroma
        }
        let total = weight.reduce(0, +)
        let meanChroma = total / Double(pixels.count)

        // Score each hue together with its neighbours (±20°): one colour such as
        // red often spans several bins, from pinkish to orange.
        let around = { (i: Int) in (-2...2).map { (i + $0 + bins) % bins } }
        let score = (0..<bins).map { i in around(i).map { weight[$0] }.reduce(0, +) }
        guard total > 0, let first = score.indices.max(by: { score[$0] < score[$1] }) else { return [.warmWhite] }
        // No real colour: almost none at all, or a little scattered over every hue (noise).
        if meanChroma < 0.012 || (meanChroma < 0.04 && score[first] < total * 0.25) { return [.warmWhite] }

        func distance(_ i: Int) -> Int { min(abs(i - first), bins - abs(i - first)) }
        func strongest(_ candidates: [Int]) -> Int? { candidates.max { score[$0] < score[$1] } }
        let second = strongest(score.indices.filter { distance($0) >= 6 && score[$0] >= total * 0.04 })  // ≥60° away
            ?? strongest(score.indices.filter { distance($0) >= 3 && weight[$0] >= total * 0.03 }) // a neighbour ≥30° away

        func colour(_ i: Int) -> RGB {
            let w = around(i).map { weight[$0] }.reduce(0, +)
            let r = around(i).map { sums[$0].r }.reduce(0, +) / w
            let g = around(i).map { sums[$0].g }.reduce(0, +) / w
            let b = around(i).map { sums[$0].b }.reduce(0, +) / w
            // Brightness is set separately, so show the hue at full value. The bulbs
            // wash pale colours out to white, so keep saturation at 80-100%.
            let (h, s, _) = RGB(r: r, g: g, b: b).hsv
            return RGB(h: h, s: 0.8 + 0.2 * s, v: 1)
        }
        if let second { return [colour(first), colour(second)] }
        // Single-hue cover: one lamp 15° one way, the other 15° the other way.
        let (h, s, v) = colour(first).hsv
        let turn = { (degrees: Double) in (h + degrees / 360 + 1).truncatingRemainder(dividingBy: 1) }
        return [RGB(h: turn(-15), s: s, v: v), RGB(h: turn(15), s: s, v: v)]
    }

    private static func downsample(_ image: NSImage, size: Int = 48) -> [RGB]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map {
            RGB(r: Double(bytes[$0]) / 255, g: Double(bytes[$0 + 1]) / 255, b: Double(bytes[$0 + 2]) / 255)
        }
    }
}

import CoreGraphics
import Foundation

/// The "Edit photo" sliders. Sliders run -100...100 (exposure in stops, -3...3), 0 leaves a picture as it is.
public struct AdjustOptions: Sendable, Equatable {
    public enum Flip: String, Sendable { case none, horizontal, vertical }

    public var exposure = 0.0
    public var contrast = 0
    public var highlights = 0
    public var shadows = 0
    public var saturation = 0
    public var temperature = 0
    public var tint = 0
    public var clarity = 0
    public var dehaze = 0
    public var sharpness = 0
    public var noiseReduction = 0
    public var grain = 0
    public var vignette = 0
    /// Clockwise degrees: 0, 90, 180 or 270.
    public var rotate = 0
    public var flip = Flip.none
    public var grayscale = false

    public init() {}

    public var isIdentity: Bool { self == AdjustOptions() }
}

/// A port of `apply_edit` in pomeloo/tools/image.py, same formulas in the same order, on 8-bit sRGB pixels.
/// Two things differ from the Windows app by nature: the grain is a different (but fixed) random pattern, and
/// blurs use a three-pass box approximation of the Gaussian, as Pillow does too, with slightly different edges.
enum ImageAdjust {
    static func apply(_ image: CGImage, _ options: AdjustOptions, cancel: CancelFlag) throws -> CGImage {
        let width = image.width, height = image.height
        var pixels = try ImagePixels.straightRGBA(image)

        if options.noiseReduction != 0 {
            let smoothed = try median5(pixels, width: width, height: height, cancel: cancel)
            blend(&pixels, with: smoothed, amount: min(1, Double(options.noiseReduction) / 100))
        }
        if options.dehaze != 0 {
            var stretched = pixels
            autoContrast(&stretched, cutoff: 2)
            blend(&pixels, with: stretched, amount: min(1, Double(abs(options.dehaze)) / 100))
        }
        try cancel.check()
        tone(&pixels, width: width, height: height, options)

        if options.clarity != 0 {
            try cancel.check()
            unsharpMask(&pixels, width: width, height: height, radius: Double(max(width, height)) / 80,
                        percent: Double(Int(Double(options.clarity) * 1.2)), threshold: 2)
        }
        if options.sharpness != 0 {
            try cancel.check()
            sharpen(&pixels, width: width, height: height, factor: 1 + Double(options.sharpness) / 50)
        }

        var (outWidth, outHeight) = (width, height)
        switch ((options.rotate % 360) + 360) % 360 {
        case 90: (pixels, outWidth, outHeight) = (rotated90(pixels, width, height, clockwise: true), height, width)
        case 180: pixels = rotated180(pixels, width, height)
        case 270: (pixels, outWidth, outHeight) = (rotated90(pixels, width, height, clockwise: false), height, width)
        default: break
        }
        switch options.flip {
        case .horizontal: pixels = mirrored(pixels, outWidth, outHeight, horizontal: true)
        case .vertical: pixels = mirrored(pixels, outWidth, outHeight, horizontal: false)
        case .none: break
        }
        return try ImagePixels.image(fromStraightRGBA: pixels, width: outWidth, height: outHeight)
    }

    // MARK: tone (exposure ... grain), one pass over the pixels

    private static func tone(_ pixels: inout [UInt8], width: Int, height: Int, _ o: AdjustOptions) {
        let needed = o.exposure != 0 || o.contrast != 0 || o.highlights != 0 || o.shadows != 0 || o.saturation != 0
            || o.temperature != 0 || o.tint != 0 || o.grayscale || o.vignette != 0 || o.grain != 0
        guard needed else { return }
        let scale = Float(pow(2.0, o.exposure))
        let highlights = Float(o.highlights) / 200, shadows = Float(o.shadows) / 200
        let contrast = 1 + Float(o.contrast) / 100
        let t = Float(o.temperature) / 400, g = Float(o.tint) / 400
        let saturation: Float = o.grayscale ? 0 : 1 + Float(o.saturation) / 100
        let vignette = Float(o.vignette) / 100
        let grain = Float(o.grain) / 600
        var noise = Noise(seed: 0)
        let halfW = Float(width) / 2, halfH = Float(height) / 2
        let sqrt2 = Float(2).squareRoot()

        pixels.withUnsafeMutableBufferPointer { p in
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    var r = Float(p[i]) / 255 * scale, gr = Float(p[i + 1]) / 255 * scale, b = Float(p[i + 2]) / 255 * scale
                    let lum = 0.299 * r + 0.587 * gr + 0.114 * b
                    if o.highlights != 0 { let d = highlights * lum * lum; r += d; gr += d; b += d }
                    if o.shadows != 0 { let d = shadows * (1 - lum) * (1 - lum); r += d; gr += d; b += d }
                    if o.contrast != 0 { r = (r - 0.5) * contrast + 0.5; gr = (gr - 0.5) * contrast + 0.5; b = (b - 0.5) * contrast + 0.5 }
                    if o.temperature != 0 || o.tint != 0 { r *= 1 + t; gr *= 1 - g; b *= 1 - t }
                    if o.saturation != 0 || o.grayscale {
                        let gray = 0.299 * r + 0.587 * gr + 0.114 * b
                        r = gray + (r - gray) * saturation; gr = gray + (gr - gray) * saturation; b = gray + (b - gray) * saturation
                    }
                    if o.vignette != 0 {
                        let dx = (Float(x) - halfW) / halfW, dy = (Float(y) - halfH) / halfH
                        let radius = (dx * dx + dy * dy).squareRoot() / sqrt2
                        let factor = 1 - vignette * radius * radius
                        r *= factor; gr *= factor; b *= factor
                    }
                    if o.grain != 0 { let n = noise.normal() * grain; r += n; gr += n; b += n }
                    p[i] = byte(r); p[i + 1] = byte(gr); p[i + 2] = byte(b)
                }
            }
        }
    }

    /// 0...1 to 0...255, clamped and truncated like `astype(uint8)`.
    private static func byte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, value * 255)))
    }

    /// A fixed random sequence: the same grain for the same picture every time.
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

        private mutating func next() -> Float {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z >> 40) / Float(1 << 24)
        }

        /// Standard normal (Box-Muller).
        mutating func normal() -> Float {
            let u1 = max(next(), 1e-7), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    // MARK: blending, stretching

    /// `Image.blend(a, b, amount)`: a * (1 - amount) + b * amount on the colour channels.
    private static func blend(_ a: inout [UInt8], with b: [UInt8], amount: Double) {
        let k = Float(amount)
        a.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                for c in 0..<3 { p[i + c] = UInt8(max(0, min(255, Float(p[i + c]) * (1 - k) + Float(b[i + c]) * k))) }
                i += 4
            }
        }
    }

    /// `ImageOps.autocontrast(cutoff=2)`: per channel, the darkest and brightest 2% are ignored and the rest is stretched to 0...255.
    private static func autoContrast(_ pixels: inout [UInt8], cutoff: Int) {
        for channel in 0..<3 {
            var histogram = [Int](repeating: 0, count: 256)
            var i = channel
            while i < pixels.count { histogram[Int(pixels[i])] += 1; i += 4 }
            let total = histogram.reduce(0, +)
            var cut = total * cutoff / 100
            for level in 0..<256 {  // the low end
                if cut > histogram[level] { cut -= histogram[level]; histogram[level] = 0 } else { histogram[level] -= cut; cut = 0 }
                if cut <= 0 { break }
            }
            cut = total * cutoff / 100
            for level in stride(from: 255, through: 0, by: -1) {  // the high end
                if cut > histogram[level] { cut -= histogram[level]; histogram[level] = 0 } else { histogram[level] -= cut; cut = 0 }
                if cut <= 0 { break }
            }
            guard let low = histogram.firstIndex(where: { $0 > 0 }), let high = histogram.lastIndex(where: { $0 > 0 }), high > low else { continue }
            let scale = 255 / Float(high - low), offset = -Float(low) * scale
            var table = [UInt8](repeating: 0, count: 256)
            for level in 0..<256 { table[level] = UInt8(max(0, min(255, Float(level) * scale + offset))) }
            i = channel
            while i < pixels.count { pixels[i] = table[Int(pixels[i])]; i += 4 }
        }
    }

    // MARK: filters

    /// A 5 by 5 median on the colour channels; the two-pixel border is left as it is, like Pillow's rank filter.
    private static func median5(_ pixels: [UInt8], width: Int, height: Int, cancel: CancelFlag) throws -> [UInt8] {
        var out = pixels
        guard width > 4, height > 4 else { return out }
        var window = [UInt8](repeating: 0, count: 25)
        for y in 2..<(height - 2) {
            try cancel.check()
            for x in 2..<(width - 2) {
                for channel in 0..<3 {
                    var n = 0
                    for dy in -2...2 { for dx in -2...2 { window[n] = pixels[((y + dy) * width + x + dx) * 4 + channel]; n += 1 } }
                    out[(y * width + x) * 4 + channel] = window.sorted()[12]
                }
            }
        }
        return out
    }

    /// Adds back the difference from a blurred copy where it is bigger than the threshold (`UnsharpMask`).
    private static func unsharpMask(_ pixels: inout [UInt8], width: Int, height: Int, radius: Double, percent: Double, threshold: Int) {
        for channel in 0..<3 {
            var plane = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) { plane[i] = Float(pixels[i * 4 + channel]) }
            let blurred = gaussian(plane, width: width, height: height, sigma: Float(radius))
            for i in 0..<(width * height) {
                let original = plane[i]
                let difference = original - blurred[i]
                if abs(difference) > Float(threshold) {
                    pixels[i * 4 + channel] = UInt8(max(0, min(255, original + difference * Float(percent) / 100)))
                }
            }
        }
    }

    /// `ImageEnhance.Sharpness`: the picture pushed away from its smoothed copy by `factor`.
    private static func sharpen(_ pixels: inout [UInt8], width: Int, height: Int, factor: Double) {
        guard width > 2, height > 2 else { return }
        let source = pixels
        let k = Float(factor)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                for channel in 0..<3 {
                    var sum: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let weight: Float = (dx == 0 && dy == 0) ? 5 : 1
                            sum += weight * Float(source[((y + dy) * width + x + dx) * 4 + channel])
                        }
                    }
                    let smooth = sum / 13
                    let original = Float(source[(y * width + x) * 4 + channel])
                    pixels[(y * width + x) * 4 + channel] = UInt8(max(0, min(255, smooth + (original - smooth) * k)))
                }
            }
        }
    }

    /// A Gaussian blur as three box blurs in each direction.
    private static func gaussian(_ plane: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let n: Float = 3
        let ideal = (12 * sigma * sigma / n + 1).squareRoot()
        var low = Int(ideal.rounded(.down))
        if low % 2 == 0 { low -= 1 }
        let high = low + 2
        let split = Int(((12 * sigma * sigma - n * Float(low * low) - 4 * n * Float(low) - 3 * n) / (-4 * Float(low) - 4)).rounded())
        var current = plane
        for pass in 0..<3 {
            let radius = ((pass < split ? low : high) - 1) / 2
            current = boxBlur(current, width: width, height: height, radius: max(0, radius), horizontal: true)
            current = boxBlur(current, width: width, height: height, radius: max(0, radius), horizontal: false)
        }
        return current
    }

    private static func boxBlur(_ plane: [Float], width: Int, height: Int, radius: Int, horizontal: Bool) -> [Float] {
        guard radius > 0 else { return plane }
        var out = plane
        let length = horizontal ? width : height
        let lines = horizontal ? height : width
        let window = Float(2 * radius + 1)
        for line in 0..<lines {
            func index(_ i: Int) -> Int { horizontal ? line * width + min(max(i, 0), length - 1) : min(max(i, 0), length - 1) * width + line }
            var sum: Float = 0
            for i in -radius...radius { sum += plane[index(i)] }
            for i in 0..<length {
                out[horizontal ? line * width + i : i * width + line] = sum / window
                sum += plane[index(i + radius + 1)] - plane[index(i - radius)]
            }
        }
        return out
    }

    // MARK: turning

    /// Quarter turns, exact: no resampling.
    private static func rotated90(_ pixels: [UInt8], _ width: Int, _ height: Int, clockwise: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width {
                let (nx, ny) = clockwise ? (height - 1 - y, x) : (y, width - 1 - x)
                let from = (y * width + x) * 4, to = (ny * height + nx) * 4
                for c in 0..<4 { out[to + c] = pixels[from + c] }
            }
        }
        return out
    }

    private static func rotated180(_ pixels: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count)
        for i in 0..<(width * height) {
            let to = (width * height - 1 - i) * 4
            for c in 0..<4 { out[to + c] = pixels[i * 4 + c] }
        }
        return out
    }

    private static func mirrored(_ pixels: [UInt8], _ width: Int, _ height: Int, horizontal: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width {
                let (nx, ny) = horizontal ? (width - 1 - x, y) : (x, height - 1 - y)
                let from = (y * width + x) * 4, to = (ny * width + nx) * 4
                for c in 0..<4 { out[to + c] = pixels[from + c] }
            }
        }
        return out
    }
}

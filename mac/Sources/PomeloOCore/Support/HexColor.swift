import CoreGraphics
import Foundation

enum HexColor {
    /// `#rrggbb` (the `#` is optional). Anything else gives `fallback`.
    static func cgColor(_ hex: String, fallback: CGColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) -> CGColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return fallback }
        // sRGB on purpose: CGColor(red:green:blue:alpha:) is in a generic space and comes out a few steps off
        return CGColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

import AppKit

enum CSSColorParser {
    /// cooViewer-oxr.35: 一般的な CSS 色表記を解釈し、ネイティブ余白と
    /// ページ CSS が同じ解決済み色を共有できるようにする。
    static func parse(_ css: String) -> CGColor? {
        let value = css.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("#") {
            let source = String(value.dropFirst())
            let expanded: String
            switch source.count {
            case 3, 4:
                expanded = source.map { "\($0)\($0)" }.joined()
            case 6, 8:
                expanded = source
            default:
                return nil
            }
            guard let encoded = UInt64(expanded, radix: 16) else { return nil }
            let hasAlpha = expanded.count == 8
            let redShift = hasAlpha ? 24 : 16
            let greenShift = hasAlpha ? 16 : 8
            let blueShift = hasAlpha ? 8 : 0
            let alpha = hasAlpha ? Double(encoded & 0xFF) / 255 : 1
            return cssColor(red: Double((encoded >> redShift) & 0xFF) / 255,
                            green: Double((encoded >> greenShift) & 0xFF) / 255,
                            blue: Double((encoded >> blueShift) & 0xFF) / 255,
                            alpha: alpha)
        }

        if let named = cssNamedColors[value] {
            return cssColor(red: Double(named.0) / 255,
                            green: Double(named.1) / 255,
                            blue: Double(named.2) / 255,
                            alpha: named.3)
        }

        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else {
            return nil
        }
        let function = String(value[..<open])
        let content = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let components = content
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        if function == "rgb" || function == "rgba" {
            guard components.count == 3 || components.count == 4,
                  let red = cssRGBComponent(components[0]),
                  let green = cssRGBComponent(components[1]),
                  let blue = cssRGBComponent(components[2]),
                  let alpha = components.count == 4
                    ? cssAlphaComponent(components[3]) : 1
            else { return nil }
            return cssColor(red: red, green: green, blue: blue, alpha: alpha)
        }

        if function == "hsl" || function == "hsla" {
            guard components.count == 3 || components.count == 4,
                  let hue = cssHue(components[0]),
                  let saturation = cssPercentage(components[1]),
                  let lightness = cssPercentage(components[2]),
                  let alpha = components.count == 4
                    ? cssAlphaComponent(components[3]) : 1
            else { return nil }
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            let sector = hue / 60
            let x = chroma * (1 - abs(sector.truncatingRemainder(
                dividingBy: 2) - 1))
            let (r1, g1, b1): (Double, Double, Double)
            switch sector {
            case 0..<1: (r1, g1, b1) = (chroma, x, 0)
            case 1..<2: (r1, g1, b1) = (x, chroma, 0)
            case 2..<3: (r1, g1, b1) = (0, chroma, x)
            case 3..<4: (r1, g1, b1) = (0, x, chroma)
            case 4..<5: (r1, g1, b1) = (x, 0, chroma)
            default: (r1, g1, b1) = (chroma, 0, x)
            }
            let match = lightness - chroma / 2
            return cssColor(red: r1 + match, green: g1 + match,
                            blue: b1 + match, alpha: alpha)
        }
        return nil
    }

    private static func cssColor(red: Double, green: Double, blue: Double,
                                 alpha: Double) -> CGColor {
        CGColor(srgbRed: CGFloat(min(1, max(0, red))),
                green: CGFloat(min(1, max(0, green))),
                blue: CGFloat(min(1, max(0, blue))),
                alpha: CGFloat(min(1, max(0, alpha))))
    }

    private static func cssRGBComponent(_ value: String) -> Double? {
        if value.hasSuffix("%") {
            return cssPercentage(value)
        }
        guard let number = Double(value), number.isFinite else { return nil }
        return min(255, max(0, number)) / 255
    }

    private static func cssAlphaComponent(_ value: String) -> Double? {
        if value.hasSuffix("%") { return cssPercentage(value) }
        guard let number = Double(value), number.isFinite else { return nil }
        return min(1, max(0, number))
    }

    private static func cssPercentage(_ value: String) -> Double? {
        guard value.hasSuffix("%"),
              let number = Double(value.dropLast()), number.isFinite else {
            return nil
        }
        return min(100, max(0, number)) / 100
    }

    private static func cssHue(_ value: String) -> Double? {
        let degrees: Double?
        if value.hasSuffix("turn") {
            degrees = Double(value.dropLast(4)).map { $0 * 360 }
        } else if value.hasSuffix("grad") {
            degrees = Double(value.dropLast(4)).map { $0 * 0.9 }
        } else if value.hasSuffix("rad") {
            degrees = Double(value.dropLast(3)).map { $0 * 180 / .pi }
        } else if value.hasSuffix("deg") {
            degrees = Double(value.dropLast(3))
        } else {
            degrees = Double(value)
        }
        guard let degrees, degrees.isFinite else { return nil }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    private static let cssNamedColors: [String: (UInt8, UInt8, UInt8, Double)] = [
        "aqua": (0, 255, 255, 1), "black": (0, 0, 0, 1),
        "blue": (0, 0, 255, 1), "fuchsia": (255, 0, 255, 1),
        "gray": (128, 128, 128, 1), "grey": (128, 128, 128, 1),
        "green": (0, 128, 0, 1), "lime": (0, 255, 0, 1),
        "maroon": (128, 0, 0, 1), "navy": (0, 0, 128, 1),
        "olive": (128, 128, 0, 1), "purple": (128, 0, 128, 1),
        "red": (255, 0, 0, 1), "silver": (192, 192, 192, 1),
        "teal": (0, 128, 128, 1), "white": (255, 255, 255, 1),
        "yellow": (255, 255, 0, 1), "transparent": (0, 0, 0, 0),
        "ivory": (255, 255, 240, 1), "beige": (245, 245, 220, 1),
        "linen": (250, 240, 230, 1), "wheat": (245, 222, 179, 1),
        "cornsilk": (255, 248, 220, 1), "floralwhite": (255, 250, 240, 1),
        "oldlace": (253, 245, 230, 1), "antiquewhite": (250, 235, 215, 1),
        "papayawhip": (255, 239, 213, 1), "seashell": (255, 245, 238, 1),
        "snow": (255, 250, 250, 1), "whitesmoke": (245, 245, 245, 1),
        "ghostwhite": (248, 248, 255, 1), "mintcream": (245, 255, 250, 1),
        "honeydew": (240, 255, 240, 1), "azure": (240, 255, 255, 1),
        "aliceblue": (240, 248, 255, 1), "lavender": (230, 230, 250, 1),
    ]
}

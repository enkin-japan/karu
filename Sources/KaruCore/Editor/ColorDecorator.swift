import Foundation
import CoreGraphics

/// Pure CSS-colour scanner for the inline colour swatches (T12.15).
///
/// A stateless parser that finds colour literals in a range of text and returns
/// their (UTF-16) ranges plus the resolved RGBA value. The editor paints a tiny
/// swatch before each hit **live, every frame** (`EditorTextView.drawBackground`)
/// only while the CSS language is active; nothing is ever stored ("画出来不存起来",
/// ARCHITECTURE.md §3).
///
/// Recognises the common CSS colour forms: `#RGB` / `#RRGGBB` / `#RRGGBBAA`,
/// `rgb()` / `rgba()`, `hsl()` / `hsla()`, and a small fixed table of ~20 named
/// colours (matched whole-word so `background` never lights up on `round`). No
/// large data tables are embedded — the named set is a tiny static constant and
/// every regex is compiled lazily once.
public enum ColorDecorator {
    /// Straight RGBA, each channel in 0...1.
    public typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    /// One recognised colour: its (UTF-16) range and resolved value.
    public typealias Match = (range: NSRange, color: RGBA)

    // MARK: - Named colours (the common ~20, 0...255 components)

    /// The common CSS named colours we light up. Deliberately small — a full CSS
    /// table is ~150 entries of dead weight; these cover the vast majority of
    /// hand-written stylesheets.
    static let namedColors: [String: (r: Int, g: Int, b: Int)] = [
        "red": (255, 0, 0),
        "green": (0, 128, 0),
        "blue": (0, 0, 255),
        "black": (0, 0, 0),
        "white": (255, 255, 255),
        "gray": (128, 128, 128),
        "orange": (255, 165, 0),
        "yellow": (255, 255, 0),
        "purple": (128, 0, 128),
        "pink": (255, 192, 203),
        "brown": (165, 42, 42),
        "cyan": (0, 255, 255),
        "magenta": (255, 0, 255),
        "lime": (0, 255, 0),
        "navy": (0, 0, 128),
        "teal": (0, 128, 128),
        "olive": (128, 128, 0),
        "maroon": (128, 0, 0),
        "silver": (192, 192, 192),
        "gold": (255, 215, 0),
    ]

    // MARK: - Lazily compiled regexes (same pattern as the language tokenizers)

    /// `#RGB` / `#RRGGBB` / `#RRGGBBAA`. Longest form listed first so the ordered
    /// ICU alternation prefers it; the trailing `\b` stops a 6-digit match from
    /// eating the first six of a 7-digit run.
    private static let hexRegex = try! NSRegularExpression(
        pattern: "#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\\b")

    /// `rgb(r,g,b)` / `rgba(r,g,b,a)` — integer channels, optional float alpha.
    private static let rgbRegex = try! NSRegularExpression(
        pattern: "rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*(?:,\\s*([0-9]*\\.?[0-9]+)\\s*)?\\)",
        options: [.caseInsensitive])

    /// `hsl(h,s%,l%)` / `hsla(h,s%,l%,a)`.
    private static let hslRegex = try! NSRegularExpression(
        pattern: "hsla?\\(\\s*(\\d+)\\s*,\\s*(\\d+)%\\s*,\\s*(\\d+)%\\s*(?:,\\s*([0-9]*\\.?[0-9]+)\\s*)?\\)",
        options: [.caseInsensitive])

    /// The named-colour set, whole-word and case-insensitive.
    private static let namedRegex: NSRegularExpression = {
        let alternation = namedColors.keys.sorted().joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(?:\(alternation))\\b",
                                        options: [.caseInsensitive])
    }()

    // MARK: - Scanning

    /// Scans `range` of `text` for colour literals and returns each hit sorted by
    /// start offset. Pure and storage-free.
    public static func colorMatches(in text: String, range: NSRange) -> [Match] {
        let ns = text as NSString
        let clamped = NSRange(location: max(0, range.location),
                              length: min(range.length, ns.length - max(0, range.location)))
        guard clamped.location >= 0, clamped.length > 0 else { return [] }

        var matches: [Match] = []

        hexRegex.enumerateMatches(in: text, range: clamped) { result, _, _ in
            guard let result, let color = hexColor(ns.substring(with: result.range)) else { return }
            matches.append((range: result.range, color: color))
        }
        rgbRegex.enumerateMatches(in: text, range: clamped) { result, _, _ in
            guard let result else { return }
            matches.append((range: result.range, color: rgbColor(result, in: ns)))
        }
        hslRegex.enumerateMatches(in: text, range: clamped) { result, _, _ in
            guard let result else { return }
            matches.append((range: result.range, color: hslColor(result, in: ns)))
        }
        namedRegex.enumerateMatches(in: text, range: clamped) { result, _, _ in
            guard let result,
                  let rgb = namedColors[ns.substring(with: result.range).lowercased()] else { return }
            matches.append((range: result.range,
                            color: (CGFloat(rgb.r) / 255, CGFloat(rgb.g) / 255, CGFloat(rgb.b) / 255, 1)))
        }

        return matches.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Parsers (each pure / testable)

    /// Parses a `#RGB` / `#RRGGBB` / `#RRGGBBAA` literal (leading `#` required).
    static func hexColor(_ literal: String) -> RGBA? {
        var hex = Substring(literal)
        guard hex.first == "#" else { return nil }
        hex = hex.dropFirst()

        func channel(_ s: Substring) -> CGFloat? {
            guard let v = Int(s, radix: 16) else { return nil }
            return CGFloat(v) / 255
        }

        switch hex.count {
        case 3:
            // Each nibble is doubled: #abc → #aabbcc.
            let chars = Array(hex)
            guard let r = channel(Substring(String([chars[0], chars[0]]))),
                  let g = channel(Substring(String([chars[1], chars[1]]))),
                  let b = channel(Substring(String([chars[2], chars[2]]))) else { return nil }
            return (r, g, b, 1)
        case 6, 8:
            let chars = Array(hex)
            guard let r = channel(Substring(String(chars[0...1]))),
                  let g = channel(Substring(String(chars[2...3]))),
                  let b = channel(Substring(String(chars[4...5]))) else { return nil }
            let a: CGFloat = hex.count == 8
                ? (channel(Substring(String(chars[6...7]))) ?? 1)
                : 1
            return (r, g, b, a)
        default:
            return nil
        }
    }

    private static func group(_ result: NSTextCheckingResult, _ index: Int, in ns: NSString) -> String? {
        let range = result.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    private static func rgbColor(_ result: NSTextCheckingResult, in ns: NSString) -> RGBA {
        let r = (group(result, 1, in: ns).flatMap { Double($0) }) ?? 0
        let g = (group(result, 2, in: ns).flatMap { Double($0) }) ?? 0
        let b = (group(result, 3, in: ns).flatMap { Double($0) }) ?? 0
        let a = (group(result, 4, in: ns).flatMap { Double($0) }) ?? 1
        return (clamp01(r / 255), clamp01(g / 255), clamp01(b / 255), clamp01(a))
    }

    private static func hslColor(_ result: NSTextCheckingResult, in ns: NSString) -> RGBA {
        let h = (group(result, 1, in: ns).flatMap { Double($0) }) ?? 0
        let s = (group(result, 2, in: ns).flatMap { Double($0) }) ?? 0
        let l = (group(result, 3, in: ns).flatMap { Double($0) }) ?? 0
        let a = (group(result, 4, in: ns).flatMap { Double($0) }) ?? 1
        return hslToRGB(h: h, s: s / 100, l: l / 100, a: clamp01(a))
    }

    /// Converts HSL (h in degrees, s/l in 0...1) to RGBA. Standard CSS formula;
    /// factored out so the conversion can be unit-tested directly.
    static func hslToRGB(h: Double, s: Double, l: Double, a: CGFloat = 1) -> RGBA {
        let hue = h.truncatingRemainder(dividingBy: 360)
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch hue {
        case 0..<60:    (r1, g1, b1) = (c, x, 0)
        case 60..<120:  (r1, g1, b1) = (x, c, 0)
        case 120..<180: (r1, g1, b1) = (0, c, x)
        case 180..<240: (r1, g1, b1) = (0, x, c)
        case 240..<300: (r1, g1, b1) = (x, 0, c)
        default:        (r1, g1, b1) = (c, 0, x)
        }
        return (clamp01(r1 + m), clamp01(g1 + m), clamp01(b1 + m), a)
    }

    private static func clamp01<T: BinaryFloatingPoint>(_ v: T) -> CGFloat {
        CGFloat(min(1, max(0, v)))
    }
}

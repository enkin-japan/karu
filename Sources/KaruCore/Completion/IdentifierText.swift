import Foundation

/// Unicode identifier boundaries and case folding on UTF-16 text for
/// completion (M17 T17.5, plan §5.5 "字符边界").
///
/// An identifier is a run of *part* characters whose first character is a
/// *start* character: letters (any script, BMP or not), `_`, and — for
/// JavaScript / TypeScript — `$`; parts add decimal digits, letter numbers,
/// combining marks and connector punctuation. Surrogate pairs are read as one
/// scalar, so a non-BMP letter never splits an identifier and a range never
/// ends inside a pair. ASCII takes a table-free fast path.
enum IdentifierText {
    /// Languages whose identifiers may contain `$`.
    static func allowsDollar(_ languageIdentifier: String) -> Bool {
        languageIdentifier == "javascript" || languageIdentifier == "typescript"
            || languageIdentifier == "typescriptreact"
    }

    @inline(__always)
    static func isASCIIStart(_ u: UInt16, dollar: Bool) -> Bool {
        (u >= 97 && u <= 122) || (u >= 65 && u <= 90) || u == 95 || (dollar && u == 36)
    }

    @inline(__always)
    static func isASCIIPart(_ u: UInt16, dollar: Bool) -> Bool {
        isASCIIStart(u, dollar: dollar) || (u >= 48 && u <= 57)
    }

    static func isStart(_ scalar: Unicode.Scalar, dollar: Bool) -> Bool {
        if scalar.value < 128 { return isASCIIStart(UInt16(scalar.value), dollar: dollar) }
        return scalar.properties.isAlphabetic
    }

    static func isPart(_ scalar: Unicode.Scalar, dollar: Bool) -> Bool {
        if scalar.value < 128 { return isASCIIPart(UInt16(scalar.value), dollar: dollar) }
        let properties = scalar.properties
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .connectorPunctuation:
            return true
        default:
            return false
        }
    }

    @inline(__always) static func isHighSurrogate(_ u: UInt16) -> Bool { u >= 0xD800 && u <= 0xDBFF }
    @inline(__always) static func isLowSurrogate(_ u: UInt16) -> Bool { u >= 0xDC00 && u <= 0xDFFF }

    /// The scalar starting at `index` and its UTF-16 length (a lone surrogate
    /// reads as U+FFFD, length 1).
    static func scalar(at index: Int, in text: NSString) -> (Unicode.Scalar, Int) {
        let u = text.character(at: index)
        if isHighSurrogate(u), index + 1 < text.length {
            let low = text.character(at: index + 1)
            if isLowSurrogate(low) {
                let value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                return (Unicode.Scalar(value) ?? "\u{FFFD}", 2)
            }
        }
        return (Unicode.Scalar(u) ?? "\u{FFFD}", 1)
    }

    /// The scalar ending at `index` (exclusive) and its UTF-16 length.
    static func scalar(before index: Int, in text: NSString) -> (Unicode.Scalar, Int) {
        let u = text.character(at: index - 1)
        if isLowSurrogate(u), index >= 2 {
            let high = text.character(at: index - 2)
            if isHighSurrogate(high) {
                let value = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(u) - 0xDC00)
                return (Unicode.Scalar(value) ?? "\u{FFFD}", 2)
            }
        }
        return (Unicode.Scalar(u) ?? "\u{FFFD}", 1)
    }

    /// Start of the run of part characters ending at `caret`, scanning at
    /// most `limit` units back; nil when the run is longer than that.
    static func runStart(before caret: Int, in text: NSString, dollar: Bool, limit: Int = 256) -> Int? {
        var start = caret
        while start > 0 {
            let u = text.character(at: start - 1)
            if u < 128 {
                guard isASCIIPart(u, dollar: dollar) else { break }
                start -= 1
            } else {
                let (scalar, length) = scalar(before: start, in: text)
                guard isPart(scalar, dollar: dollar) else { break }
                start -= length
            }
            if caret - start > limit { return nil }
        }
        return start
    }

    /// End of the run of part characters starting at `caret` (at most
    /// `limit` units on).
    static func runEnd(after caret: Int, in text: NSString, dollar: Bool, limit: Int = 256) -> Int {
        var end = caret
        let length = text.length
        while end < length, end - caret < limit {
            let u = text.character(at: end)
            if u < 128 {
                guard isASCIIPart(u, dollar: dollar) else { break }
                end += 1
            } else {
                let (scalar, count) = scalar(at: end, in: text)
                guard isPart(scalar, dollar: dollar) else { break }
                end += count
            }
        }
        return end
    }

    /// Whether `units` (an identifier run) starts with a start character.
    static func startsIdentifier(_ units: some Collection<UInt16>, dollar: Bool) -> Bool {
        guard let first = units.first else { return false }
        if first < 128 { return isASCIIStart(first, dollar: dollar) }
        var iterator = units.makeIterator()
        var decoder = UTF16()
        if case .scalarValue(let scalar) = decoder.decode(&iterator) { return isStart(scalar, dollar: dollar) }
        return false
    }
}

/// Simple per-unit case folding (lowercase) for case-insensitive matching:
/// ASCII by arithmetic, other BMP units by their single-unit lowercase
/// mapping when there is one, everything else unchanged.
enum CaseFold {
    @inline(__always)
    static func fold(_ u: UInt16) -> UInt16 {
        if u < 128 { return u >= 65 && u <= 90 ? u + 32 : u }
        return foldNonASCII(u)
    }

    static func foldNonASCII(_ u: UInt16) -> UInt16 {
        // Caseless blocks (CJK, kana, hangul, symbols) and surrogates.
        if u >= 0x2E80 && u < 0xA640 || u >= 0xAC00 || u < 0xC0 && u != 0xB5 { return u }
        guard let scalar = Unicode.Scalar(u), scalar.properties.changesWhenLowercased else { return u }
        let mapped = scalar.properties.lowercaseMapping.utf16
        return mapped.count == 1 ? mapped.first! : u
    }

    static func folded(_ s: String) -> [UInt16] { s.utf16.map(fold) }
}

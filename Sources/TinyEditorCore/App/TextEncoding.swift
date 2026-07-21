import Foundation

/// The manual-override encodings offered by File ▸ Reopen with Encoding.
///
/// The automatic detection chain in `DocumentController.decodeText(from:)` covers
/// the common cases, but when it guesses wrong this list is the user's fallback:
/// each case maps to a concrete `String.Encoding` used to force-decode the file.
///
/// `rawValue` is the stable tag stored on a menu item's `representedObject`;
/// `displayName` is the conventional label (deliberately *not* localized — these
/// are standard encoding names, treated like proper nouns).
public enum TextEncoding: String, CaseIterable, Sendable {
    case utf8
    case utf16LE
    case utf16BE
    case gb18030
    case big5
    case shiftJIS
    case eucKR
    case isoLatin1
    case windows1252

    /// Conventional display name shown in the menu ("UTF-8", "Shift JIS", …).
    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .gb18030: return "GB18030"
        case .big5: return "Big5"
        case .shiftJIS: return "Shift JIS"
        case .eucKR: return "EUC-KR"
        case .isoLatin1: return "ISO Latin-1"
        case .windows1252: return "Windows-1252"
        }
    }

    /// The Foundation encoding this case decodes with. The CJK legacy encodings
    /// have no `String.Encoding` constant, so they are resolved through the
    /// CoreFoundation encoding registry.
    public var encoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .gb18030: return Self.cfEncoding(CFStringEncodings.GB_18030_2000)
        case .big5: return Self.cfEncoding(CFStringEncodings.big5)
        case .shiftJIS: return .shiftJIS
        case .eucKR: return Self.cfEncoding(CFStringEncodings.EUC_KR)
        case .isoLatin1: return .isoLatin1
        case .windows1252: return .windowsCP1252
        }
    }

    private static func cfEncoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(cf.rawValue)))
    }
}

import Foundation

/// Which stream a piece of output came from. `system` is for the UI's own
/// status lines (e.g. "compile failed", "exit 0") — the engine never emits it.
public enum RunOutputStream: String, Sendable {
    case stdout, stderr, system
}

/// A decoded, ANSI-stripped piece of output.
public struct RunOutputChunk: Equatable, Sendable {
    public var stream: RunOutputStream
    public var text: String

    public init(stream: RunOutputStream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Retained output for the output panel: at most `capacity` UTF-8 bytes,
/// dropping the oldest text first and setting `isTruncated`. Consecutive
/// chunks of the same stream are merged so segment count stays small.
public struct RunOutputBuffer: Equatable, Sendable {
    public static let defaultCapacity = 1_000_000

    public let capacity: Int
    public private(set) var segments: [RunOutputChunk] = []
    public private(set) var isTruncated = false
    /// Retained size in UTF-8 bytes.
    public private(set) var byteCount = 0

    public init(capacity: Int = RunOutputBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { byteCount == 0 }

    /// All retained text, streams concatenated in arrival order.
    public var text: String { segments.map(\.text).joined() }

    public mutating func append(_ chunk: RunOutputChunk) {
        guard !chunk.text.isEmpty else { return }
        if let last = segments.indices.last, segments[last].stream == chunk.stream {
            segments[last].text += chunk.text
        } else {
            segments.append(chunk)
        }
        byteCount += chunk.text.utf8.count
        trim()
    }

    public mutating func append(_ stream: RunOutputStream, _ text: String) {
        append(RunOutputChunk(stream: stream, text: text))
    }

    /// Marks output as truncated (used when the engine dropped bytes before
    /// they reached the buffer).
    public mutating func markTruncated() { isTruncated = true }

    public mutating func clear() {
        segments.removeAll()
        byteCount = 0
        isTruncated = false
    }

    private mutating func trim() {
        var excess = byteCount - capacity
        guard excess > 0 else { return }
        isTruncated = true
        var dropSegments = 0
        while excess > 0, dropSegments < segments.count {
            let size = segments[dropSegments].text.utf8.count
            if size <= excess {
                excess -= size
                byteCount -= size
                dropSegments += 1
            } else {
                let text = segments[dropSegments].text
                var cut = text.utf8.index(text.utf8.startIndex, offsetBy: excess)
                // Advance to a Character boundary so no scalar is split.
                while cut < text.endIndex, cut.samePosition(in: text) == nil { cut = text.utf8.index(after: cut) }
                let rest = String(text[cut...])
                byteCount -= size - rest.utf8.count
                segments[dropSegments].text = rest
                excess = 0
            }
        }
        segments.removeFirst(dropSegments)
    }
}

/// Incremental UTF-8 decoding: a multi-byte character split across reads is
/// held back until complete instead of becoming U+FFFD. Genuinely invalid
/// bytes still decode as U+FFFD.
public struct UTF8StreamDecoder: Sendable {
    private var carry: [UInt8] = []

    public init() {}

    public mutating func decode<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var data = carry
        carry.removeAll(keepingCapacity: true)
        data.append(contentsOf: bytes)
        let cut = Self.completePrefixLength(data)
        if cut < data.count { carry = Array(data[cut...]) }
        return String(decoding: data[..<cut], as: UTF8.self)
    }

    /// Flushes any held-back bytes (lossily) at end of stream.
    public mutating func finish() -> String {
        defer { carry.removeAll() }
        return carry.isEmpty ? "" : String(decoding: carry, as: UTF8.self)
    }

    /// Length of `data` excluding a trailing incomplete sequence.
    static func completePrefixLength(_ data: [UInt8]) -> Int {
        let n = data.count
        var i = n - 1
        let lowest = max(0, n - 4)
        while i >= lowest {
            let byte = data[i]
            if byte & 0xC0 == 0x80 { i -= 1; continue } // continuation byte
            let need: Int
            switch byte {
            case 0xF0...0xF7: need = 4
            case 0xE0...0xEF: need = 3
            case 0xC0...0xDF: need = 2
            default: need = 1
            }
            return n - i < need ? i : n
        }
        return n
    }
}

/// Removes ANSI escape sequences (CSI `ESC [ … final`, OSC `ESC ] … BEL|ESC \`,
/// and two/three-byte `ESC x` sequences) from a stream of text, keeping state
/// across chunk boundaries.
public struct ANSIStripper: Sendable {
    private enum State: Sendable { case text, escape, csi, osc, oscEscape, intermediate }
    private var state: State = .text

    public init() {}

    public mutating func strip(_ text: String) -> String {
        guard state != .text || text.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == "\u{9B}" }) else {
            return text
        }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch state {
            case .text:
                if v == 0x1B { state = .escape } else if v == 0x9B { state = .csi } else { out.append(scalar) }
            case .escape:
                switch v {
                case 0x5B: state = .csi                    // [
                case 0x5D: state = .osc                    // ]
                case 0x50, 0x58, 0x5E, 0x5F: state = .osc  // DCS / SOS / PM / APC: string until ST
                case 0x20...0x2F: state = .intermediate    // e.g. ESC ( B
                default: state = .text                     // two-byte sequence: drop it
                }
            case .intermediate:
                if !(0x20...0x2F).contains(v) { state = .text }
            case .csi:
                if (0x40...0x7E).contains(v) { state = .text }
            case .osc:
                if v == 0x07 { state = .text } else if v == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = v == 0x5C ? .text : .osc
            }
        }
        return String(out)
    }
}

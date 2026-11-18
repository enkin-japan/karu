import Foundation

/// Bounds every built-in formatter respects, so a small hostile or accidental
/// input cannot crash the app or exhaust memory (RELIABILITY-PLAN F7, D6).
///
/// Measured before these existed: 30 000 levels of nesting (a 60 KB JSON or a
/// 210 KB XML file) overflowed the stack, and 10 000 levels in a 20 KB JSON
/// produced 200 MB of indentation.
public struct FormatLimits: Equatable, Sendable {
    /// Deepest container / element nesting that is still formatted.
    public var maxDepth: Int
    /// The output may be at most `outputFactor` × the input size, plus
    /// `outputSlackBytes`, both in UTF-8 bytes.
    public var outputFactor: Int
    public var outputSlackBytes: Int

    public init(maxDepth: Int, outputFactor: Int, outputSlackBytes: Int) {
        self.maxDepth = maxDepth
        self.outputFactor = outputFactor
        self.outputSlackBytes = outputSlackBytes
    }

    /// 512 levels; 8 × input + 1 MB. Initial values, to be revisited with
    /// measurements.
    public static let standard = FormatLimits(maxDepth: 512, outputFactor: 8, outputSlackBytes: 1 << 20)

    /// Largest output, in UTF-8 bytes, allowed for an input of `inputBytes`
    /// (saturating, never overflows).
    public func maxOutputBytes(forInputBytes inputBytes: Int) -> Int {
        let (scaled, overflowScaled) = max(0, inputBytes).multipliedReportingOverflow(by: outputFactor)
        guard !overflowScaled else { return .max }
        let (total, overflowTotal) = scaled.addingReportingOverflow(outputSlackBytes)
        return overflowTotal ? .max : total
    }
}

/// Thrown by a formatter that stopped at one of the ``FormatLimits``. The
/// document is never changed when this is thrown.
public enum FormatLimitError: Error, Equatable {
    /// Nesting went past `limit` levels at 1-based `line` of the input.
    case nestingTooDeep(line: Int, limit: Int)
    /// The formatted result would exceed `limitBytes` UTF-8 bytes.
    case outputTooLarge(limitBytes: Int)
}

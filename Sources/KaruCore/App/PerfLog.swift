import Foundation

/// Opt-in timing log for latency work (M17 T17.0).
///
/// Enabled only when the process starts with `KARU_PERFLOG=<path>`; the
/// decision is made once, into the `isEnabled` constant, so every call site's
/// disabled path is a single branch (`if PerfLog.isEnabled { … }`) and no
/// timestamps, strings or buffers are created. Nothing is written — not even
/// an empty file — when the variable is unset.
///
/// When enabled, events are appended to the file as tab-separated lines:
///
///     uptime_ns <TAB> event <TAB> duration_us <TAB> key=value <TAB> key=value …
///
/// `uptime_ns` is `DispatchTime.now().uptimeNanoseconds` when the event was
/// recorded (the same clock family as `NSEvent.timestamp` /
/// `ProcessInfo.systemUptime`). Lines are buffered in memory under a lock and
/// written by a private utility queue at most every 0.5 s, plus a synchronous
/// `flush()` at app termination. The file is appended to, never truncated.
/// `scripts/m17/perf-summary.py` summarises a log.
public enum PerfLog {
    /// Whether `KARU_PERFLOG` named a log file at launch. Decided once.
    public static let isEnabled: Bool = sink != nil

    private static let sink: Sink? = {
        guard let path = ProcessInfo.processInfo.environment["KARU_PERFLOG"],
              !path.isEmpty else { return nil }
        return Sink(path: path)
    }()

    /// Monotonic now, in nanoseconds since boot (excluding sleep).
    @inline(__always)
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Records `event` whose duration runs from `startNs` (a `now()` reading)
    /// to now. No-op when disabled.
    public static func record(_ event: String, since startNs: UInt64,
                              _ fields: KeyValuePairs<String, Any> = [:]) {
        guard let sink else { return }
        let end = now()
        let durationUs = Double(end &- startNs) / 1000.0
        sink.append(line(end, event, durationUs, fields))
    }

    /// Records `event` with an explicitly measured duration in seconds (used
    /// when the start is an `NSEvent.timestamp`). No-op when disabled.
    public static func record(_ event: String, durationSeconds: Double,
                              _ fields: KeyValuePairs<String, Any> = [:]) {
        guard let sink else { return }
        sink.append(line(now(), event, durationSeconds * 1_000_000, fields))
    }

    /// Writes any buffered lines synchronously. Called at app termination;
    /// cheap no-op when disabled.
    public static func flush() {
        sink?.flushNow()
    }

    private static func line(_ uptime: UInt64, _ event: String, _ durationUs: Double,
                             _ fields: KeyValuePairs<String, Any>) -> String {
        var out = "\(uptime)\t\(event)\t" + String(format: "%.1f", durationUs)
        for (key, value) in fields {
            // Keep the TSV well-formed whatever a value contains.
            let text = String(describing: value)
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            out += "\t\(key)=\(text)"
        }
        return out + "\n"
    }

    /// Lock-protected line buffer plus the file it drains into. All file I/O
    /// runs on `queue`, never on the caller's (main) thread, except the final
    /// synchronous flush at termination.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [String] = []
        private var flushScheduled = false
        private let queue = DispatchQueue(label: "dev.enkin.Karu.PerfLog", qos: .utility)
        private let path: String
        private var handle: FileHandle?
        private var openFailed = false

        init(path: String) { self.path = path }

        func append(_ line: String) {
            lock.lock()
            buffer.append(line)
            let schedule = !flushScheduled
            flushScheduled = true
            lock.unlock()
            guard schedule else { return }
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in drain() }
        }

        func flushNow() {
            queue.sync { drain() }
        }

        /// Runs on `queue` only.
        private func drain() {
            lock.lock()
            let lines = buffer
            buffer.removeAll(keepingCapacity: true)
            flushScheduled = false
            lock.unlock()
            guard !lines.isEmpty, let handle = openHandle() else { return }
            handle.write(Data(lines.joined().utf8))
        }

        /// Runs on `queue` only. Opens (creating if needed) the log for append.
        private func openHandle() -> FileHandle? {
            if let handle { return handle }
            guard !openFailed else { return nil }
            let fm = FileManager.default
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil)
            }
            guard let h = FileHandle(forWritingAtPath: path) else {
                openFailed = true
                return nil
            }
            h.seekToEndOfFile()
            handle = h
            return h
        }
    }
}

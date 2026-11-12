import CryptoKit
import Darwin
import Foundation

// MARK: - Errors, phases, cancellation

/// Why an install failed. Plain data; `ToolchainMessages` localizes it.
public enum ToolchainInstallError: Error, Equatable, Sendable {
    case cancelled
    /// Transport failure (description attached).
    case network(String)
    /// Non-2xx HTTP status.
    case httpStatus(Int)
    /// The URL (after redirects) is not https.
    case insecureURL(String)
    case checksumMismatch(expected: String, actual: String)
    /// `tar` failed (stderr excerpt or exit status attached).
    case extractionFailed(String)
    /// An expected executable is absent / not executable after extraction
    /// (relative path attached).
    case executableMissing(String)
    /// Creating / moving / removing files failed (description attached).
    case filesystem(String)
}

/// Progress of a running install (or uninstall) for one toolchain.
public enum ToolchainActivity: Equatable, Sendable {
    case downloading(received: Int64, expected: Int64)
    case verifying
    case extracting
    case uninstalling

    /// Download fraction in 0...1, `nil` for the other phases.
    public var fraction: Double? {
        guard case .downloading(let received, let expected) = self, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

/// Thread-safe cancellation flag with one-shot handlers (used to cancel the
/// URLSession task immediately rather than at the next poll).
public final class ToolchainCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var nextToken = 0

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = handlers.values
        handlers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }

    /// Registers `handler`; runs it at once if already cancelled. Returns a
    /// token for `removeHandler` (`nil` when it already ran).
    @discardableResult
    public func onCancel(_ handler: @escaping @Sendable () -> Void) -> Int? {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return nil }
        nextToken += 1
        let token = nextToken
        handlers[token] = handler
        lock.unlock()
        return token
    }

    public func removeHandler(_ token: Int?) {
        guard let token else { return }
        lock.lock(); handlers[token] = nil; lock.unlock()
    }

    func check() throws {
        if isCancelled { throw ToolchainInstallError.cancelled }
    }
}

// MARK: - Download

/// Streams `url` to `destination` (a file that must not exist yet). Blocks
/// the calling thread until done; must honour `cancellation` promptly.
/// Returns the final URL after redirects.
public protocol ToolchainDownloader: Sendable {
    func download(from url: URL, to destination: URL, cancellation: ToolchainCancellation,
                  progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void) throws -> URL
}

/// Production downloader: one ephemeral `URLSession` (no cookies, no cache)
/// per download, a download task that streams to disk, redirects to non-https
/// refused. The session is invalidated when the download ends.
public struct URLSessionToolchainDownloader: ToolchainDownloader {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func download(from url: URL, to destination: URL, cancellation: ToolchainCancellation,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) throws -> URL {
        try cancellation.check()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: url)
        let token = cancellation.onCancel { task.cancel() }
        defer { cancellation.removeHandler(token) }
        task.resume()
        delegate.done.wait()
        try cancellation.check()
        if let error = delegate.failure { throw error }
        return delegate.finalURL ?? url
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64, Int64?) -> Void
        let done = DispatchSemaphore(value: 0)
        // Written on the session's serial delegate queue, read after `done`.
        var failure: ToolchainInstallError?
        var finalURL: URL?

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard request.url?.scheme?.lowercased() == "https" else {
                failure = .insecureURL(request.url?.absoluteString ?? "")
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard failure == nil else { return }
            finalURL = downloadTask.response?.url ?? downloadTask.currentRequest?.url
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = .httpStatus(http.statusCode)
                return
            }
            do {
                // The temp file is deleted when this returns: move it now.
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = .filesystem(error.localizedDescription)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if failure == nil, let error {
                failure = (error as? URLError)?.code == .cancelled ? .cancelled : .network(error.localizedDescription)
            }
            done.signal()
        }
    }
}

// MARK: - Installer

/// Downloads, verifies, extracts and atomically places one toolchain
/// (ARCHITECTURE.md §6). Blocking and stateless: the manager runs each
/// install on its own background thread. Never touches anything outside the
/// store root and never adds or strips extended attributes (quarantine).
public struct ToolchainInstaller: Sendable {
    public static let chunkSize = 1 << 20

    public var store: ToolchainStore
    public var downloader: any ToolchainDownloader
    /// Tests may feed `file://` fixtures; production requires https.
    var allowsFileURLs = false
    /// The system tar; tests substitute a slow stand-in to exercise cancel.
    var tarPath = "/usr/bin/tar"

    public init(store: ToolchainStore = ToolchainStore(),
                downloader: any ToolchainDownloader = URLSessionToolchainDownloader()) {
        self.store = store
        self.downloader = downloader
    }

    /// Runs the whole install. `progress` is called on the calling thread,
    /// throttled to whole-percent steps while downloading. On any failure or
    /// cancellation the staging directory is removed and nothing is placed.
    @discardableResult
    public func install(_ entry: ToolchainManifestEntry, cancellation: ToolchainCancellation,
                        progress: @escaping @Sendable (ToolchainActivity) -> Void) throws -> ToolchainStore.Installation {
        let fm = FileManager.default
        let staging = store.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw ToolchainInstallError.filesystem(error.localizedDescription)
        }
        defer { try? ToolchainStore.forceRemove(staging) }

        // 1. Download (streamed to a staging file).
        try cancellation.check()
        let archive = staging.appendingPathComponent("archive")
        let throttle = ProgressThrottle(fallbackTotal: entry.downloadSize, report: progress)
        progress(.downloading(received: 0, expected: entry.downloadSize))
        let finalURL: URL
        do {
            finalURL = try downloader.download(from: entry.url, to: archive, cancellation: cancellation,
                                               progress: { throttle.update($0, $1) })
        } catch let error as ToolchainInstallError {
            throw error
        } catch {
            throw ToolchainInstallError.network(error.localizedDescription)
        }
        try cancellation.check()
        let scheme = finalURL.scheme?.lowercased()
        guard scheme == "https" || (allowsFileURLs && finalURL.isFileURL) else {
            throw ToolchainInstallError.insecureURL(finalURL.absoluteString)
        }

        // 2. Verify.
        progress(.verifying)
        let actual = try Self.digest(of: archive, algorithm: entry.checksum.algorithm, cancellation: cancellation)
        guard actual == entry.checksum.hex else {
            try? fm.removeItem(at: archive)
            throw ToolchainInstallError.checksumMismatch(expected: entry.checksum.hex, actual: actual)
        }

        // 3. Extract with the system tar, then validate the executables.
        try cancellation.check()
        progress(.extracting)
        let tree = staging.appendingPathComponent("x", isDirectory: true)
        do {
            try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        } catch {
            throw ToolchainInstallError.filesystem(error.localizedDescription)
        }
        try Self.extract(archive: archive, into: tree, cancellation: cancellation, tar: tarPath)
        try? fm.removeItem(at: archive)
        try cancellation.check()
        try Self.validate(tree: tree, entry: entry)

        // 4. Place atomically (rename on the same volume), then drop other versions.
        do {
            try ToolchainStore.writeMarker(.init(id: entry.id, version: entry.version, binPath: entry.binPath), into: tree)
        } catch {
            throw ToolchainInstallError.filesystem(error.localizedDescription)
        }
        try cancellation.check()
        let destination = store.versionDirectory(entry.id, version: entry.version)
        do {
            try fm.createDirectory(at: store.toolchainDirectory(entry.id), withIntermediateDirectories: true)
            let previous = staging.appendingPathComponent("previous", isDirectory: true)
            let replacing = fm.fileExists(atPath: destination.path)
            if replacing { try fm.moveItem(at: destination, to: previous) }
            do {
                try fm.moveItem(at: tree, to: destination)
            } catch {
                if replacing { try? fm.moveItem(at: previous, to: destination) }
                throw error
            }
        } catch {
            throw ToolchainInstallError.filesystem(error.localizedDescription)
        }
        for version in store.installedVersions(entry.id) where version != entry.version {
            try? ToolchainStore.forceRemove(store.versionDirectory(entry.id, version: version))
        }
        return ToolchainStore.Installation(
            id: entry.id, version: entry.version, directory: destination,
            binDirectory: ToolchainStore.binDirectory(in: destination, binPath: entry.binPath))
    }

    // MARK: Steps

    /// Lowercase hex digest, streamed in `chunkSize` reads.
    public static func digest(of file: URL, algorithm: ToolchainChecksumAlgorithm,
                              cancellation: ToolchainCancellation = ToolchainCancellation()) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw ToolchainInstallError.filesystem(error.localizedDescription)
        }
        defer { try? handle.close() }
        var sha256 = SHA256()
        var sha512 = SHA512()
        while true {
            try cancellation.check()
            let chunk: Data
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) ?? Data() }
            } catch {
                throw ToolchainInstallError.filesystem(error.localizedDescription)
            }
            if chunk.isEmpty { break }
            switch algorithm {
            case .sha256: sha256.update(data: chunk)
            case .sha512: sha512.update(data: chunk)
            }
        }
        let bytes: [UInt8]
        switch algorithm {
        case .sha256: bytes = Array(sha256.finalize())
        case .sha512: bytes = Array(sha512.finalize())
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `/usr/bin/tar -xf <archive> -C <directory>` as a child process in its
    /// own process group; SIGKILLed on cancellation (polled every 50 ms).
    static func extract(archive: URL, into directory: URL, cancellation: ToolchainCancellation,
                        tar: String = "/usr/bin/tar", extraArguments: [String] = []) throws {
        let pipe: (read: Int32, write: Int32)
        do { pipe = try RunSpawn.makePipe() } catch {
            throw ToolchainInstallError.extractionFailed((error as? RunSpawn.Failure)?.message ?? "\(error)")
        }
        let pid: pid_t
        do {
            pid = try RunSpawn.spawn(executable: tar, arguments: extraArguments + ["-xf", archive.path, "-C", directory.path],
                                     environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"],
                                     workingDirectory: nil, stdin: .devNull, stdout: .devNull, stderr: .fd(pipe.write))
        } catch {
            close(pipe.read); close(pipe.write)
            throw ToolchainInstallError.extractionFailed((error as? RunSpawn.Failure)?.message ?? "\(error)")
        }
        close(pipe.write)
        RunSpawn.setNonBlocking(pipe.read)
        defer { close(pipe.read) }
        // Kill at once on cancel (e.g. app termination, when the polling loop
        // below never gets another turn); the loop still reaps and throws.
        let killToken = cancellation.onCancel { killpg(pid, SIGKILL) }
        defer { if let killToken { cancellation.removeHandler(killToken) } }

        var errorOutput = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var status: Int32 = 0
        var eof = false
        func drain() {
            while true {
                let n = buffer.withUnsafeMutableBytes { read(pipe.read, $0.baseAddress, $0.count) }
                if n > 0 {
                    if errorOutput.count < 8192 { errorOutput.append(contentsOf: buffer[0..<n]) }
                    continue
                }
                if n == 0 { eof = true }
                return
            }
        }
        while true {
            if cancellation.isCancelled {
                killpg(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                throw ToolchainInstallError.cancelled
            }
            if !eof {
                var pfd = pollfd(fd: pipe.read, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, 50)
                drain()
            } else {
                usleep(50_000)
            }
            if waitpid(pid, &status, WNOHANG) == pid { break }
        }
        drain()
        // The cancel handler may have SIGKILLed tar before the loop noticed.
        if cancellation.isCancelled { throw ToolchainInstallError.cancelled }
        let termination = RunSpawn.termination(fromWaitStatus: status)
        guard termination.isSuccess else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            switch termination {
            case .exited(let code): throw ToolchainInstallError.extractionFailed(message ?? "tar exit \(code)")
            case .signaled(let signal): throw ToolchainInstallError.extractionFailed(message ?? "tar signal \(signal)")
            }
        }
    }

    /// Every expected executable exists inside the tree, is executable and
    /// does not resolve (through symlinks) outside it.
    static func validate(tree: URL, entry: ToolchainManifestEntry) throws {
        let bin = ToolchainStore.binDirectory(in: tree, binPath: entry.binPath)
        let treeRoot = tree.resolvingSymlinksInPath().path + "/"
        for name in entry.executables {
            let url = bin.appendingPathComponent(name)
            let relative = entry.binPath == "." ? name : entry.binPath + "/" + name
            guard ToolchainStore.isExecutableFile(url),
                  url.resolvingSymlinksInPath().path.hasPrefix(treeRoot) else {
                throw ToolchainInstallError.executableMissing(relative)
            }
        }
    }
}

/// Reports download progress at most once per whole percent.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let fallbackTotal: Int64
    private let report: @Sendable (ToolchainActivity) -> Void
    private var lastPercent = -1

    init(fallbackTotal: Int64, report: @escaping @Sendable (ToolchainActivity) -> Void) {
        self.fallbackTotal = fallbackTotal
        self.report = report
    }

    func update(_ received: Int64, _ expected: Int64?) {
        let total = max(expected ?? fallbackTotal, received, 1)
        let percent = Int(received * 100 / total)
        lock.lock()
        guard percent != lastPercent else { lock.unlock(); return }
        lastPercent = percent
        lock.unlock()
        report(.downloading(received: received, expected: total))
    }
}

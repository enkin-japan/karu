import Darwin
import Foundation

// MARK: - Public result types

/// How a run ended.
public enum RunCompletion: Equatable, Sendable {
    /// The run step ended (a user stop shows up as `.signaled`).
    case finished(RunTermination)
    /// The compile step failed (non-zero exit or signal, including a stop
    /// during compilation); the run step was not started.
    case compileFailed(RunTermination)
    /// A step could not be spawned (`RunFailure.launchFailed`).
    case launchFailed(RunFailure)
    /// Stopped between a successful compile and the run step.
    case cancelled
}

public struct RunResult: Equatable, Sendable {
    public var completion: RunCompletion
    /// Wall-clock time from `start` to completion (compile included).
    public var duration: TimeInterval
    /// `stop()` (or `stopAll`) was requested during the run.
    public var wasStopped: Bool
}

// MARK: - Runner

/// Executes a `RunPlan` (compile step, then run step) and streams output to
/// the main actor. One run at a time per instance; the caller checks
/// `isRunning` before `start`. Holds no thread or queue between runs: each
/// run creates one serial queue whose dispatch sources are torn down when it
/// ends.
@MainActor
public final class CodeRunner {
    public enum Phase: Equatable, Sendable { case compiling, running }

    /// Coalesced output (≤ ~30 deliveries/s), already appended to `output`.
    public var onOutput: (([RunOutputChunk]) -> Void)?
    public var onPhaseChange: ((Phase) -> Void)?
    public var onFinish: ((RunResult) -> Void)?
    /// Remove the plan's temp directory when the run ends (default true).
    public var cleansUpWorkspace = true

    /// Retained output (~1 MB cap, oldest dropped, `isTruncated` set).
    public private(set) var output: RunOutputBuffer
    public private(set) var isRunning = false
    public private(set) var phase: Phase?
    public private(set) var plan: RunPlan?

    private let active = ActiveChild()
    private var queue: DispatchQueue?
    private var pump: OutputPump?
    private var generation = 0
    private var startedAt: ContinuousClock.Instant?
    private var stopRequested = false

    public init(outputCapacity: Int = RunOutputBuffer.defaultCapacity) {
        output = RunOutputBuffer(capacity: outputCapacity)
    }

    deinit {
        // Never leave an unreachable process tree behind.
        active.child?.terminate()
    }

    /// Starts `plan` (its workspace must already be prepared). Clears
    /// `output`. Returns false (and does nothing) if a run is in progress.
    @discardableResult
    public func start(_ plan: RunPlan) -> Bool {
        guard !isRunning else { return false }
        generation += 1
        let gen = generation
        self.plan = plan
        isRunning = true
        stopRequested = false
        startedAt = .now
        output.clear()

        let queue = DispatchQueue(label: "dev.enkin.Karu.run.\(gen)")
        self.queue = queue
        pump = OutputPump(queue: queue) { [weak self] chunks, dropped, ack in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(chunks, dropped: dropped, generation: gen) }
                ack()
            }
        }
        if let compile = plan.compile {
            launch(compile, phase: .compiling)
        } else {
            launch(plan.run, phase: .running)
        }
        return true
    }

    /// Writes `line` + "\n" to the child's stdin. No-op when not running.
    public func send(line: String) {
        guard isRunning else { return }
        active.child?.write(Data((line + "\n").utf8))
    }

    /// Closes the child's stdin (EOF). No-op when not running.
    public func sendEOF() {
        guard isRunning else { return }
        active.child?.closeStdin()
    }

    /// SIGTERM to the current step's process group, SIGKILL after 2 s.
    public func stop() {
        guard isRunning else { return }
        stopRequested = true
        active.child?.terminate()
    }

    /// Clears retained output (e.g. the panel's "Clear" button).
    public func clearOutput() { output.clear() }

    /// Appends a UI status line (`.system` stream: run header, exit status,
    /// stdin echo, failure message) to `output`, so the panel renders a single
    /// bounded buffer. Not delivered through `onOutput`; works while idle.
    public func appendSystem(_ text: String) { output.append(.system, text) }

    /// Stops every live run process in the app (window close / app
    /// termination). `force` sends SIGKILL immediately instead of SIGTERM →
    /// SIGKILL, for use when the app is about to exit. Callable from any thread.
    public nonisolated static func stopAll(force: Bool = false) {
        RunRegistry.shared.stopAll(force: force)
    }

    /// Number of live run processes app-wide (diagnostics / tests).
    public nonisolated static var activeProcessCount: Int { RunRegistry.shared.count }

    // MARK: Internals

    private func launch(_ command: RunCommand, phase: Phase) {
        guard let queue, let pump, let plan else { return }
        self.phase = phase
        onPhaseChange?(phase)
        let gen = generation
        do {
            let child = try ChildProcess(
                command: command,
                environment: plan.environment.merging(command.environmentOverrides) { $1 },
                queue: queue,
                onData: { stream, bytes in pump.ingest(stream, bytes) },
                onExit: { [weak self] termination in
                    pump.finish {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.stepExited(termination, generation: gen) }
                        }
                    }
                })
            active.child = child
        } catch {
            let message = (error as? RunSpawn.Failure)?.message ?? "\(error)"
            finish(.launchFailed(.launchFailed(message)))
        }
    }

    private func receive(_ chunks: [RunOutputChunk], dropped: Bool, generation gen: Int) {
        guard gen == generation else { return }
        for chunk in chunks { output.append(chunk) }
        if dropped { output.markTruncated() }
        if !chunks.isEmpty { onOutput?(chunks) }
    }

    private func stepExited(_ termination: RunTermination, generation gen: Int) {
        guard gen == generation, isRunning, let plan else { return }
        active.child = nil
        if phase == .compiling {
            if !termination.isSuccess {
                finish(.compileFailed(termination))
            } else if stopRequested {
                finish(.cancelled)
            } else {
                launch(plan.run, phase: .running)
            }
        } else {
            finish(.finished(termination))
        }
    }

    private func finish(_ completion: RunCompletion) {
        let elapsed = startedAt.map { ContinuousClock.now - $0 } ?? .zero
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let result = RunResult(completion: completion, duration: seconds, wasStopped: stopRequested)
        isRunning = false
        phase = nil
        active.child = nil
        queue = nil
        pump = nil
        startedAt = nil
        if cleansUpWorkspace, let plan {
            DispatchQueue.global(qos: .utility).async { RunWorkspace.cleanup(plan) }
        }
        onFinish?(result)
    }
}

/// Lock-protected holder so `CodeRunner.deinit` (nonisolated) can reach the
/// live child.
private final class ActiveChild: @unchecked Sendable {
    private let lock = NSLock()
    private var _child: ChildProcess?
    var child: ChildProcess? {
        get { lock.lock(); defer { lock.unlock() }; return _child }
        set { lock.lock(); _child = newValue; lock.unlock() }
    }
}

/// App-wide set of live children. Also keeps each child alive until it has
/// been reaped, independent of its runner's lifetime.
final class RunRegistry: @unchecked Sendable {
    static let shared = RunRegistry()
    private let lock = NSLock()
    private var children: [ObjectIdentifier: ChildProcess] = [:]

    func insert(_ child: ChildProcess) {
        lock.lock(); children[ObjectIdentifier(child)] = child; lock.unlock()
    }

    func remove(_ child: ChildProcess) {
        lock.lock(); children[ObjectIdentifier(child)] = nil; lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return children.count }

    func stopAll(force: Bool) {
        lock.lock(); let all = Array(children.values); lock.unlock()
        for child in all { force ? child.kill() : child.terminate() }
    }
}

// MARK: - Output pump (queue-confined)

/// Decodes (incremental UTF-8), strips ANSI and coalesces output on the run
/// queue, delivering at most ~30 batches per second with one batch in flight
/// at a time. While a batch is in flight, pending output is capped at ~1 MB
/// (oldest dropped, reported as `dropped`).
final class OutputPump: @unchecked Sendable {
    typealias Deliver = @Sendable (_ chunks: [RunOutputChunk], _ dropped: Bool,
                                   _ ack: @escaping @Sendable () -> Void) -> Void

    static let minimumInterval: TimeInterval = 1.0 / 30

    private let queue: DispatchQueue
    private let deliver: Deliver
    private var decoders: [RunOutputStream: UTF8StreamDecoder] = [.stdout: .init(), .stderr: .init()]
    private var strippers: [RunOutputStream: ANSIStripper] = [.stdout: .init(), .stderr: .init()]
    private var pending = RunOutputBuffer(capacity: RunOutputBuffer.defaultCapacity)
    private var inFlight = false
    private var flushScheduled = false
    /// `systemUptime` of the last delivery (monotonic seconds).
    private var lastFlush: TimeInterval = -.infinity

    init(queue: DispatchQueue, deliver: @escaping Deliver) {
        self.queue = queue
        self.deliver = deliver
    }

    /// Called on `queue`.
    func ingest(_ stream: RunOutputStream, _ bytes: UnsafeRawBufferPointer) {
        let decoded = decoders[stream, default: .init()].decode(bytes)
        enqueue(stream, decoded)
        scheduleFlush()
    }

    /// Called on `queue` when a step ends: flushes held-back bytes and all
    /// pending output immediately, then runs `then` (still on `queue`), so
    /// the final output is dispatched to the main queue before `then`'s work.
    func finish(then: () -> Void) {
        for stream in [RunOutputStream.stdout, .stderr] {
            enqueue(stream, decoders[stream, default: .init()].finish())
        }
        decoders = [.stdout: .init(), .stderr: .init()]
        strippers = [.stdout: .init(), .stderr: .init()]
        if !pending.isEmpty || pending.isTruncated { flush() }
        then()
    }

    private func enqueue(_ stream: RunOutputStream, _ text: String) {
        guard !text.isEmpty else { return }
        let clean = strippers[stream, default: .init()].strip(text)
        pending.append(stream, clean)
    }

    private func scheduleFlush() {
        guard !inFlight, !flushScheduled, !pending.isEmpty else { return }
        let wait = lastFlush + Self.minimumInterval - ProcessInfo.processInfo.systemUptime
        if wait <= 0 {
            flush()
        } else {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                flushScheduled = false
                scheduleFlush()
            }
        }
    }

    private func flush() {
        let chunks = pending.segments
        let dropped = pending.isTruncated
        pending.clear()
        inFlight = true
        lastFlush = ProcessInfo.processInfo.systemUptime
        deliver(chunks, dropped) { [self] in
            queue.async { [self] in
                inFlight = false
                scheduleFlush()
            }
        }
    }
}

// MARK: - Child process (queue-confined)

/// One spawned child with stdin/stdout/stderr pipes. Spawning happens
/// synchronously on the caller's thread (so the pid is known immediately);
/// all I/O and exit handling run on the run's serial `queue` via dispatch
/// sources — no thread is parked per process. Mutable state is confined to
/// `queue`; `pid` is immutable, so signalling is safe from any thread.
final class ChildProcess: @unchecked Sendable {
    /// After the direct child exits, how long to wait for the pipes to reach
    /// EOF before treating leftover background processes as orphans.
    static let pipeDrainGrace: TimeInterval = 0.5
    /// SIGTERM → SIGKILL escalation delay.
    static let killEscalationDelay: TimeInterval = 2

    let pid: pid_t
    private let queue: DispatchQueue
    private let onData: @Sendable (RunOutputStream, UnsafeRawBufferPointer) -> Void
    private let onExit: @Sendable (RunTermination) -> Void

    private var stdinFD: Int32
    private var stdinBacklog = Data()
    private var stdinSource: DispatchSourceWrite?
    private var stdinCloseRequested = false
    private var readSources: [(source: DispatchSourceRead, stream: RunOutputStream)] = []
    private var processSource: DispatchSourceProcess?
    private var termination: RunTermination?
    private var completed = false
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)

    /// Spawns `command` and starts monitoring it on `queue`. `onData` and
    /// `onExit` are called on `queue`; `onExit` fires exactly once, after the
    /// child is reaped and its output pipes reached EOF (or the drain grace
    /// elapsed). The child registers itself in `RunRegistry` until then.
    init(command: RunCommand, environment: [String: String], queue: DispatchQueue,
         onData: @escaping @Sendable (RunOutputStream, UnsafeRawBufferPointer) -> Void,
         onExit: @escaping @Sendable (RunTermination) -> Void) throws {
        self.queue = queue
        self.onData = onData
        self.onExit = onExit

        var opened: [Int32] = []
        let stdinPipe: (read: Int32, write: Int32)
        let outPipe: (read: Int32, write: Int32)
        let errPipe: (read: Int32, write: Int32)
        do {
            stdinPipe = try RunSpawn.makePipe(); opened += [stdinPipe.read, stdinPipe.write]
            outPipe = try RunSpawn.makePipe(); opened += [outPipe.read, outPipe.write]
            errPipe = try RunSpawn.makePipe(); opened += [errPipe.read, errPipe.write]
            pid = try RunSpawn.spawn(executable: command.executable, arguments: command.arguments,
                                     environment: environment,
                                     workingDirectory: command.workingDirectory.path,
                                     stdin: .fd(stdinPipe.read), stdout: .fd(outPipe.write),
                                     stderr: .fd(errPipe.write))
        } catch {
            opened.forEach { close($0) }
            readBuffer.deallocate()
            throw error
        }
        close(stdinPipe.read); close(outPipe.write); close(errPipe.write)

        stdinFD = stdinPipe.write
        RunSpawn.setNonBlocking(stdinFD)
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1) // EPIPE instead of a process-killing SIGPIPE
        RunSpawn.setNonBlocking(outPipe.read)
        RunSpawn.setNonBlocking(errPipe.read)

        for (fd, stream) in [(outPipe.read, RunOutputStream.stdout), (errPipe.read, .stderr)] {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(fd: fd, stream: stream) }
            source.setCancelHandler { close(fd) }
            readSources.append((source, stream))
        }
        let proc = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        proc.setEventHandler { [weak self] in self?.reap() }
        processSource = proc

        RunRegistry.shared.insert(self)
        queue.async { [self] in
            readSources.forEach { $0.source.resume() }
            proc.resume()
            reap() // covers an exit that happened before the source was armed
        }
    }

    deinit {
        readBuffer.deallocate()
    }

    // MARK: Signals

    /// SIGTERM to the whole process group, then SIGKILL after the escalation
    /// delay if the child is unreaped or anything in its group is alive.
    func terminate() {
        killpg(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.killEscalationDelay) { [self] in
            if termination == nil || killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
    }

    /// Immediate SIGKILL to the group (app termination).
    func kill() {
        killpg(pid, SIGKILL)
    }

    // MARK: stdin

    func write(_ data: Data) {
        queue.async { [self] in
            guard stdinFD >= 0, !stdinCloseRequested, !data.isEmpty else { return }
            stdinBacklog.append(data)
            flushStdin()
        }
    }

    func closeStdin() {
        queue.async { [self] in
            guard stdinFD >= 0 else { return }
            stdinCloseRequested = true
            if stdinBacklog.isEmpty { closeStdinNow() }
        }
    }

    private func flushStdin() {
        while !stdinBacklog.isEmpty, stdinFD >= 0 {
            let n = stdinBacklog.withUnsafeBytes { Darwin.write(stdinFD, $0.baseAddress, $0.count) }
            if n > 0 {
                stdinBacklog.removeFirst(n)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                armStdinSource()
                return
            }
            // EPIPE (child closed stdin / exited) or another error: give up.
            closeStdinNow()
            return
        }
        if let source = stdinSource {
            stdinSource = nil
            source.cancel()
        }
        if stdinCloseRequested { closeStdinNow() }
    }

    private func armStdinSource() {
        guard stdinSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: stdinFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushStdin() }
        stdinSource = source
        source.resume()
    }

    private func closeStdinNow() {
        guard stdinFD >= 0 else { return }
        let fd = stdinFD
        stdinFD = -1
        stdinBacklog.removeAll()
        if let source = stdinSource {
            stdinSource = nil
            source.setCancelHandler { close(fd) }
            source.cancel()
        } else {
            close(fd)
        }
    }

    // MARK: Output / exit

    private func readAvailable(fd: Int32, stream: RunOutputStream) {
        while true {
            let n = read(fd, readBuffer.baseAddress, readBuffer.count)
            if n > 0 {
                onData(stream, UnsafeRawBufferPointer(rebasing: readBuffer[0..<n]))
                if n < readBuffer.count { return }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            closeStream(fd: fd) // EOF or hard error
            return
        }
    }

    private func closeStream(fd: Int32) {
        guard let index = readSources.firstIndex(where: { Int32($0.source.handle) == fd }) else { return }
        readSources.remove(at: index).source.cancel()
        completeIfDone()
    }

    private func reap() {
        guard termination == nil else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        termination = RunSpawn.termination(fromWaitStatus: status)
        processSource?.cancel()
        processSource = nil
        if !readSources.isEmpty {
            // A background grandchild may still hold the pipes open; give it a
            // short grace, then end the run and terminate the leftover group.
            queue.asyncAfter(deadline: .now() + Self.pipeDrainGrace) { [self] in
                guard !completed, !readSources.isEmpty else { return }
                for (source, stream) in readSources {
                    let fd = Int32(source.handle)
                    while true {
                        let n = read(fd, readBuffer.baseAddress, readBuffer.count)
                        guard n > 0 else { break }
                        onData(stream, UnsafeRawBufferPointer(rebasing: readBuffer[0..<n]))
                    }
                    source.cancel()
                }
                readSources.removeAll()
                if killpg(pid, 0) == 0 { terminate() }
                completeIfDone()
            }
        }
        completeIfDone()
    }

    private func completeIfDone() {
        guard !completed, let termination, readSources.isEmpty else { return }
        completed = true
        closeStdinNow()
        RunRegistry.shared.remove(self)
        onExit(termination)
    }
}

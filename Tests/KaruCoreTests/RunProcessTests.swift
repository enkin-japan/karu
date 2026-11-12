import Darwin
import Foundation
import Testing
@testable import KaruCore

// Output model (pure) and the process layer driven with real system tools
// only (/bin/sh, /bin/cat, /bin/sleep, /usr/bin/printf) — no language
// toolchain is required.

@Suite("Run output model")
struct RunOutputModelTests {
    @Test func decoderHoldsBackSplitMultibyteCharacters() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("a中😀b".utf8) // 1 + 3 + 4 + 1 bytes
        var out = ""
        for byte in bytes { out += decoder.decode([byte]) } // worst case: one byte per read
        out += decoder.finish()
        #expect(out == "a中😀b")
        #expect(!out.contains("\u{FFFD}"))
    }

    @Test func decoderSplitsAtEveryBoundary() {
        let bytes = Array("é中😀x".utf8)
        for cut in 0...bytes.count {
            var decoder = UTF8StreamDecoder()
            let out = decoder.decode(bytes[0..<cut]) + decoder.decode(bytes[cut...]) + decoder.finish()
            #expect(out == "é中😀x", "cut at \(cut)")
        }
    }

    @Test func decoderReplacesGenuinelyInvalidBytes() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode([0x61, 0xFF, 0x62]) == "a\u{FFFD}b")
        // A truncated sequence at end of stream is flushed lossily.
        _ = decoder.decode([0xE4, 0xB8])
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(decoder.finish() == "")
    }

    @Test func ansiStripperRemovesCSIAndOSC() {
        var s = ANSIStripper()
        #expect(s.strip("\u{1B}[1;31mred\u{1B}[0m plain") == "red plain")
        #expect(s.strip("\u{1B}]0;title\u{07}after") == "after")
        #expect(s.strip("\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
        #expect(s.strip("\u{1B}(Bcharset\u{1B}=keypad") == "charsetkeypad")
        #expect(s.strip("tab\tand\nnewline") == "tab\tand\nnewline")
    }

    @Test func ansiStripperKeepsStateAcrossChunks() {
        var s = ANSIStripper()
        #expect(s.strip("a\u{1B}") == "a")
        #expect(s.strip("[3") == "")
        #expect(s.strip("2mb") == "b")
        #expect(s.strip("\u{1B}]0;ti") == "")
        #expect(s.strip("tle\u{07}c") == "c")
    }

    @Test func bufferMergesSameStreamAndKeepsOrder() {
        var buffer = RunOutputBuffer(capacity: 100)
        buffer.append(.stdout, "a")
        buffer.append(.stdout, "b")
        buffer.append(.stderr, "E")
        buffer.append(.stdout, "c")
        buffer.append(.system, "")
        #expect(buffer.segments == [.init(stream: .stdout, text: "ab"), .init(stream: .stderr, text: "E"),
                                    .init(stream: .stdout, text: "c")])
        #expect(buffer.text == "abEc")
        #expect(buffer.byteCount == 4)
        #expect(!buffer.isTruncated)
    }

    @Test func bufferDropsOldestAndFlagsTruncation() {
        var buffer = RunOutputBuffer(capacity: 10)
        buffer.append(.stdout, "0123456")
        buffer.append(.stderr, "789AB")
        #expect(buffer.isTruncated)
        #expect(buffer.byteCount == 10)
        #expect(buffer.text == "23456789AB")
        buffer.append(.stdout, String(repeating: "z", count: 25))
        #expect(buffer.text == String(repeating: "z", count: 10))
        #expect(buffer.segments.count == 1)
        buffer.clear()
        #expect(buffer.isEmpty && !buffer.isTruncated)
    }

    @Test func bufferTrimNeverSplitsCharacters() {
        var buffer = RunOutputBuffer(capacity: 7)
        buffer.append(.stdout, "中文字") // 9 bytes → must drop a whole 3-byte char
        #expect(buffer.text == "文字")
        #expect(buffer.byteCount == 6)
        #expect(buffer.isTruncated)
    }
}

// MARK: - Process layer

private let testEnvironment: [String: String] = {
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("KARU_") }
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env
}()

/// Physical path (`/private/var/…`), matching `pwd -P`.
private func physicalPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruRunProcessTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func shellPlan(_ script: String, in dir: URL, compile: RunCommand? = nil) -> RunPlan {
    RunPlan(language: .bash, directory: dir, sourceFileName: "main.sh", sourceText: script,
            compile: compile,
            run: RunCommand(executable: "/bin/sh", arguments: ["-c", script], workingDirectory: dir),
            environment: testEnvironment)
}

/// Starts `plan` and waits (polling the main actor) for completion.
@MainActor
private final class Harness {
    let runner: CodeRunner
    var result: RunResult?
    var deliveries = 0
    var phases: [CodeRunner.Phase] = []

    init(capacity: Int = RunOutputBuffer.defaultCapacity) {
        runner = CodeRunner(outputCapacity: capacity)
        runner.cleansUpWorkspace = false
        runner.onFinish = { [unowned self] in self.result = $0 }
        runner.onOutput = { [unowned self] _ in self.deliveries += 1 }
        runner.onPhaseChange = { [unowned self] in self.phases.append($0) }
    }

    func start(_ plan: RunPlan) {
        #expect(runner.start(plan))
    }

    @discardableResult
    func wait(timeout: TimeInterval = 10) async -> RunResult? {
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return result
    }

    func waitForOutput(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !runner.output.text.contains(needle), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return runner.output.text.contains(needle)
    }

    func text(_ stream: RunOutputStream) -> String {
        runner.output.segments.filter { $0.stream == stream }.map(\.text).joined()
    }

    func run(_ plan: RunPlan, timeout: TimeInterval = 10) async -> RunResult? {
        start(plan)
        return await wait(timeout: timeout)
    }
}

@Suite("Run process layer", .serialized)
@MainActor
struct RunProcessTests {
    @Test func separatesStdoutAndStderrAndReportsExitCode() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        let result = await h.run(shellPlan("echo out1; echo err1 >&2; echo out2; exit 7", in: dir))
        #expect(result?.completion == .finished(.exited(7)))
        #expect(result?.wasStopped == false)
        #expect((result?.duration ?? -1) >= 0)
        #expect(h.text(.stdout) == "out1\nout2\n")
        #expect(h.text(.stderr) == "err1\n")
        #expect(h.phases == [.running])
        #expect(!h.runner.isRunning)
    }

    @Test func runsInTheRequestedWorkingDirectory() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        _ = await h.run(shellPlan("pwd -P", in: dir))
        #expect(h.text(.stdout) == physicalPath(dir) + "\n")
    }

    @Test func passesPlanEnvironment() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var plan = shellPlan(#"printf '%s|%s' "$KARU_RUN_TEST_VAR" "$PATH""#, in: dir)
        plan.environment["KARU_RUN_TEST_VAR"] = "v1"
        let h = Harness()
        _ = await h.run(plan)
        #expect(h.text(.stdout) == "v1|/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func reportsSignalTermination() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        let result = await h.run(shellPlan("kill -9 $$", in: dir))
        #expect(result?.completion == .finished(.signaled(SIGKILL)))
    }

    @Test func stdinLinesAndEOF() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var plan = shellPlan("", in: dir)
        plan.run = RunCommand(executable: "/bin/cat", arguments: [], workingDirectory: dir)
        let h = Harness()
        h.start(plan)
        h.runner.send(line: "hello")
        #expect(await h.waitForOutput(containing: "hello\n"))
        h.runner.send(line: "世界")
        h.runner.sendEOF()
        let result = await h.wait()
        #expect(result?.completion == .finished(.exited(0)))
        #expect(h.text(.stdout) == "hello\n世界\n")
    }

    @Test func stopKillsTheWholeProcessGroup() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        // The grandchild `sleep` would outlive a plain kill of `sh`.
        h.start(shellPlan("/bin/sleep 100 & echo pid:$!; wait", in: dir))
        #expect(await h.waitForOutput(containing: "\n"))
        let pidText = h.text(.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try #require(Int32(pidText.replacingOccurrences(of: "pid:", with: "")))
        #expect(kill(grandchild, 0) == 0)

        let stopped = Date()
        h.runner.stop()
        let result = await h.wait(timeout: 5)
        #expect(Date().timeIntervalSince(stopped) < 3)
        #expect(result?.wasStopped == true)
        #expect(result?.completion == .finished(.signaled(SIGTERM)))

        // The grandchild is gone (reaped by launchd shortly after the signal).
        let deadline = Date().addingTimeInterval(3)
        while kill(grandchild, 0) == 0, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(kill(grandchild, 0) == -1)
    }

    @Test func stopEscalatesToSIGKILL() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        h.start(shellPlan("trap '' TERM; echo ready; while :; do /bin/sleep 1; done", in: dir))
        #expect(await h.waitForOutput(containing: "ready"))
        let stopped = Date()
        h.runner.stop()
        let result = await h.wait(timeout: 6)
        let elapsed = Date().timeIntervalSince(stopped)
        #expect(result?.completion == .finished(.signaled(SIGKILL)))
        #expect(elapsed >= 1.5 && elapsed < 4.5)
    }

    @Test func stopAllStopsLiveRuns() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Harness(), b = Harness()
        a.start(shellPlan("echo a; exec /bin/sleep 100", in: dir))
        b.start(shellPlan("echo b; exec /bin/sleep 100", in: dir))
        #expect(await a.waitForOutput(containing: "a"))
        #expect(await b.waitForOutput(containing: "b"))
        #expect(CodeRunner.activeProcessCount >= 2)
        CodeRunner.stopAll(force: true)
        #expect(await a.wait(timeout: 3)?.completion == .finished(.signaled(SIGKILL)))
        #expect(await b.wait(timeout: 3)?.completion == .finished(.signaled(SIGKILL)))
        #expect(CodeRunner.activeProcessCount == 0)
    }

    @Test func backgroundLeftoverDoesNotHangTheRun() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        let started = Date()
        let result = await h.run(shellPlan("/bin/sleep 30 & echo $!", in: dir), timeout: 5)
        #expect(result?.completion == .finished(.exited(0)))
        #expect(Date().timeIntervalSince(started) < 3)
        let pid = try #require(Int32(h.text(.stdout).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(4)
        while kill(pid, 0) == 0, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(kill(pid, 0) == -1) // leftover group member terminated
    }

    @Test func outputIsCappedWithTruncationFlag() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness(capacity: 1_000)
        let result = await h.run(shellPlan("i=0; while [ $i -lt 500 ]; do echo 0123456789; i=$((i+1)); done; echo END", in: dir))
        #expect(result?.completion == .finished(.exited(0)))
        #expect(h.runner.output.isTruncated)
        #expect(h.runner.output.byteCount <= 1_000)
        #expect(h.runner.output.text.hasSuffix("0123456789\nEND\n"))
    }

    @Test func utf8SplitAcrossReadsIsDecodedIntact() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        // 中 = E4 B8 AD, split across two writes separated by a pause.
        _ = await h.run(shellPlan(#"/usr/bin/printf '\344\270'; /bin/sleep 0.2; /usr/bin/printf '\255!\n'"#, in: dir))
        #expect(h.text(.stdout) == "中!\n")
    }

    @Test func ansiSequencesAreStripped() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        _ = await h.run(shellPlan(#"/usr/bin/printf '\033[31mred\033[0m \033]0;t\007ok\n'; /usr/bin/printf '\033[1mE\033[0m\n' >&2"#, in: dir))
        #expect(h.text(.stdout) == "red ok\n")
        #expect(h.text(.stderr) == "E\n")
    }

    @Test func deliveriesAreCoalesced() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        let started = Date()
        let result = await h.run(shellPlan("i=0; while [ $i -lt 60 ]; do echo line$i; /bin/sleep 0.01; i=$((i+1)); done", in: dir))
        let elapsed = Date().timeIntervalSince(started)
        #expect(result?.completion == .finished(.exited(0)))
        #expect(h.text(.stdout).components(separatedBy: "\n").count == 61)
        // ≤ 30 deliveries per second, plus the final flush and rounding slack.
        #expect(h.deliveries <= Int(elapsed * 30) + 3, "\(h.deliveries) deliveries in \(elapsed)s")
    }

    @Test func writingAfterExitIsHarmless() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        // The child closes its stdin immediately: writes hit EPIPE, not SIGPIPE.
        h.start(shellPlan("exec 0<&-; echo closed; /bin/sleep 0.3", in: dir))
        #expect(await h.waitForOutput(containing: "closed"))
        for _ in 0..<50 { h.runner.send(line: String(repeating: "x", count: 4096)) }
        h.runner.sendEOF()
        #expect(await h.wait()?.completion == .finished(.exited(0)))
        // After exit: both are no-ops.
        h.runner.send(line: "late")
        h.runner.sendEOF()
        h.runner.stop()
        #expect(!h.runner.isRunning)
    }

    @Test func launchFailureIsReported() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var plan = shellPlan("", in: dir)
        plan.run = RunCommand(executable: dir.appendingPathComponent("missing").path, arguments: [], workingDirectory: dir)
        let h = Harness()
        let result = await h.run(plan)
        guard case .launchFailed(.launchFailed(let message))? = result?.completion else {
            Issue.record("expected launch failure, got \(String(describing: result))")
            return
        }
        #expect(message.contains("No such file"))
        #expect(!h.runner.isRunning)
        // A new run can start on the same instance.
        #expect(await h.runAgain(shellPlan("echo again", in: dir))?.completion == .finished(.exited(0)))
    }

    @Test func startWhileRunningIsRejected() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        h.start(shellPlan("exec /bin/sleep 5", in: dir))
        #expect(h.runner.isRunning)
        #expect(h.runner.start(shellPlan("echo second", in: dir)) == false)
        h.runner.stop()
        #expect(await h.wait(timeout: 4)?.wasStopped == true)
    }

    // MARK: Two-step plans with a fake compiler script

    private func fakeCompiler(in dir: URL, body: String) throws -> String {
        let path = dir.appendingPathComponent("fakecc").path
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o755)
        return path
    }

    @Test func compileFailureShortCircuits() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cc = try fakeCompiler(in: dir, body: "echo 'main.c:1: error: boom' >&2; exit 3")
        let plan = shellPlan("echo SHOULD_NOT_RUN", in: dir,
                             compile: RunCommand(executable: cc, arguments: ["main.c"], workingDirectory: dir))
        let h = Harness()
        let result = await h.run(plan)
        #expect(result?.completion == .compileFailed(.exited(3)))
        #expect(h.text(.stderr) == "main.c:1: error: boom\n")
        #expect(!h.runner.output.text.contains("SHOULD_NOT_RUN"))
        #expect(h.phases == [.compiling])
    }

    @Test func compileThenRunThroughPlanBuilder() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Writes an executable shell script to the `-o` path, like a compiler would.
        let cc = try fakeCompiler(in: dir, body: """
        out=""; prev=""
        for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
        echo "compiling $#" >&2
        printf '#!/bin/sh\\necho "ran in $(pwd -P)"\\n' > "$out"; chmod +x "$out"
        """)
        let root = dir.appendingPathComponent("runs", isDirectory: true)
        let builder = RunPlanBuilder(workspaceRoot: root, baseEnvironment: testEnvironment)
        let doc = dir.appendingPathComponent("prog.c")
        let plan = builder.makePlan(language: .c, text: "int main(void){return 0;}\r\n", documentURL: doc,
                                    tool: ResolvedTool(executable: cc, origin: .custom, searchPath: "/usr/bin:/bin"),
                                    preference: RunToolPreference(extraFlags: ["-Wall"]))
        try RunWorkspace.prepare(plan)

        let h = Harness()
        h.runner.cleansUpWorkspace = true
        let result = await h.run(plan)
        #expect(result?.completion == .finished(.exited(0)))
        #expect(h.phases == [.compiling, .running])
        #expect(h.text(.stderr) == "compiling 5\n") // -O0 -Wall main.c -o a.out
        #expect(h.text(.stdout) == "ran in \(physicalPath(dir))\n")

        // The finished run's temp directory is removed.
        let deadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: plan.directory.path), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: plan.directory.path))
    }

    @Test func stopDuringCompileDoesNotRun() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cc = try fakeCompiler(in: dir, body: "echo compiling; exec /bin/sleep 30")
        let plan = shellPlan("echo SHOULD_NOT_RUN", in: dir,
                             compile: RunCommand(executable: cc, arguments: [], workingDirectory: dir))
        let h = Harness()
        h.start(plan)
        #expect(await h.waitForOutput(containing: "compiling"))
        h.runner.stop()
        let result = await h.wait(timeout: 4)
        #expect(result?.completion == .compileFailed(.signaled(SIGTERM)))
        #expect(result?.wasStopped == true)
        #expect(!h.runner.output.text.contains("SHOULD_NOT_RUN"))
    }
}

@MainActor
private extension Harness {
    func runAgain(_ plan: RunPlan) async -> RunResult? {
        result = nil
        return await run(plan)
    }
}

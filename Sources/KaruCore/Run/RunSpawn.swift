import Darwin
import Foundation

/// Thin `posix_spawn` wrapper used by the run engine. Every child is placed in
/// its own process group (pgid == pid) so the whole tree — `go run` /
/// `dotnet run` grandchildren, `sh -c 'x &'` — can be signalled at once, which
/// Foundation's `Process` cannot do. Only the fds wired up here are inherited
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), and signal dispositions / mask are reset
/// so a child never inherits Karu's ignored SIGPIPE.
enum RunSpawn {
    struct Failure: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        init(errno code: Int32, _ what: String) {
            self.message = "\(what): \(String(cString: strerror(code)))"
        }
    }

    /// What a child's fd 0/1/2 is connected to.
    enum Stdio {
        case devNull
        case fd(Int32)
    }

    /// Creates a pipe whose both ends are close-on-exec (so concurrent spawns
    /// elsewhere in the app never inherit them).
    static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw Failure(errno: errno, "pipe") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Spawns `executable` (absolute path) with `arguments` (argv[1...]).
    /// Returns the child's pid, which is also its process-group id.
    static func spawn(executable: String,
                      arguments: [String],
                      environment: [String: String],
                      workingDirectory: String?,
                      stdin: Stdio, stdout: Stdio, stderr: Stdio) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure("posix_spawn_file_actions_init") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw Failure("posix_spawnattr_init") }
        defer { posix_spawnattr_destroy(&attr) }

        for (stdio, target) in [(stdin, Int32(0)), (stdout, Int32(1)), (stderr, Int32(2))] {
            switch stdio {
            case .devNull:
                let mode = target == 0 ? O_RDONLY : O_WRONLY
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", mode, 0)
            case .fd(let fd):
                posix_spawn_file_actions_adddup2(&actions, fd, target)
            }
        }
        if let dir = workingDirectory {
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&actions, dir)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, dir)
            }
        }

        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else { throw Failure(errno: rc, executable) }
        return pid
    }

    /// Decodes a `waitpid` status word (the WIFEXITED/WTERMSIG macros are not
    /// importable into Swift).
    static func termination(fromWaitStatus status: Int32) -> RunTermination {
        let low = status & 0x7f
        if low == 0 { return .exited((status >> 8) & 0xff) }
        return .signaled(low)
    }
}

/// How a process ended.
public enum RunTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public var isSuccess: Bool { self == .exited(0) }
}

/// Synchronous, time-limited command execution for short probes
/// (`$SHELL -l -c`, `xcode-select -p`, `java_home`). Blocks the calling
/// thread for at most `timeout`; call it off the main thread.
enum SyncCommand {
    struct Result: Equatable {
        var termination: RunTermination
        var stdout: String
    }

    /// Runs the command with stdin/stderr on /dev/null and captures stdout.
    /// Returns `nil` on spawn failure or timeout (the process group is then
    /// SIGKILLed). Stops reading once the direct child has exited, so a
    /// background grandchild keeping the pipe open cannot stall the caller.
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    timeout: TimeInterval) -> Result? {
        guard let pipe = try? RunSpawn.makePipe() else { return nil }
        let pid: pid_t
        do {
            pid = try RunSpawn.spawn(executable: executable, arguments: arguments,
                                     environment: environment, workingDirectory: nil,
                                     stdin: .devNull, stdout: .fd(pipe.write), stderr: .devNull)
        } catch {
            close(pipe.read); close(pipe.write)
            return nil
        }
        close(pipe.write)
        RunSpawn.setNonBlocking(pipe.read)
        defer { close(pipe.read) }

        let deadline = Date().addingTimeInterval(timeout)
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var status: Int32 = 0
        var exited = false
        var eof = false

        func drain() {
            while true {
                let n = buffer.withUnsafeMutableBytes { read(pipe.read, $0.baseAddress, $0.count) }
                if n > 0 { output.append(contentsOf: buffer[0..<n]); continue }
                if n == 0 { eof = true }
                return
            }
        }

        while !exited {
            if Date() >= deadline {
                killpg(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                return nil
            }
            if !eof {
                var pfd = pollfd(fd: pipe.read, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, 50)
                drain()
            } else {
                usleep(20_000)
            }
            if waitpid(pid, &status, WNOHANG) == pid { exited = true }
        }
        drain()
        return Result(termination: RunSpawn.termination(fromWaitStatus: status),
                      stdout: String(decoding: output, as: UTF8.self))
    }
}

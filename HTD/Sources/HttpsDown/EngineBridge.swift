import Foundation
import Darwin

/// Final outcome of one engine subprocess, delivered after the process group is swept and pipes are drained.
public struct EngineTaskResult {
    public var exitCode: Int32? = nil
    public var terminatedBySignal: Int32? = nil
    public var cancelled = false
    public var timedOut = false
    /// Every member of the owned process group is gone (leader reaped + group empty).
    public var groupClean = false
    /// Both pipes reached EOF on their own (no escaped holder of the write end).
    public var pipesDrained = false
    /// The engine's first event proved it is the spawned leader of its own group.
    public var readyHandshake = false
    public var stderrBytes = 0
    public var spawnError: String? = nil
}

/// One engine subprocess owned by us.
///
/// Ownership model:
///  * `posix_spawn(POSIX_SPAWN_SETPGROUP, pgroup 0)` makes the child its own group leader atomically at spawn,
///    so there is no window in which a signal could reach our own group or nobody.
///  * The leader is reaped by `waitpid` only on our waiter thread. A pid cannot be recycled while the leader is
///    unreaped, and the kernel will not reuse a pid as long as a process group with that id exists, so signals
///    to `-pgid` cannot hit an unrelated process while `groupGone` is false.
///  * After the leader exits (normally or by cancel), the group is always swept (TERM, then KILL) and checked with
///    `kill(-pgid, 0)` until empty, so orphaned grandchildren (ffmpeg, deno, ...) never survive the task.
///  * stdout/stderr are drained concurrently until EOF with per-line and retention caps.
public final class EngineTaskHandle {
    public let jobId: String
    public let generation: Int

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var ownsGroup = false
    private var leaderReaped = false
    private var groupGone = false
    private var cancelRequested = false
    private var timedOutFlag = false
    private var finished = false
    private var readyHandshake = false
    private let doneGroup = DispatchGroup()
    /// Long-lived helpers (connection assist) keep stdin open for line-delimited control messages.
    let keepStdinOpen: Bool
    private var stdinFd: Int32 = -1
    private let stdinWriteLock = NSLock()
    /// "녹화 마치고 저장" asked before the engine proved it installed its SIGUSR1 handler.
    private var gracefulPending = false
    private var gracefulSent = false

    public var gracefulStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gracefulPending || gracefulSent
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// Process-group id for diagnostics/tests (0 before spawn).
    public var processGroupId: pid_t {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    init(jobId: String, generation: Int, keepStdinOpen: Bool = false) {
        self.jobId = jobId
        self.generation = generation
        self.keepStdinOpen = keepStdinOpen
        doneGroup.enter()
    }

    /// Cooperative finish: SIGUSR1 to the engine leader only (never the group, so FFmpeg is not signalled directly).
    /// The engine installs its handler before the `ready` handshake; until the handshake arrives the request is kept
    /// pending so the default action (terminate) can never hit an unprepared process. This is not a cancel: the
    /// outcome is still decided by the engine's terminal event and the normal exit checks.
    public func requestGracefulStop() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelRequested, !leaderReaped, !gracefulSent else { return }
        if pid > 0, readyHandshake {
            gracefulSent = kill(pid, SIGUSR1) == 0
        } else {
            gracefulPending = true
        }
    }

    /// Writes one control line to a helper started with `keepStdinOpen`. Returns false once stdin is closed.
    @discardableResult
    public func sendLine(_ data: Data) -> Bool {
        stdinWriteLock.lock()
        defer { stdinWriteLock.unlock() }
        lock.lock()
        let fd = stdinFd
        lock.unlock()
        guard fd >= 0 else { return false }
        var payload = data
        if payload.last != 0x0A { payload.append(0x0A) }
        return payload.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    func closeStdin() {
        stdinWriteLock.lock()
        lock.lock()
        let fd = stdinFd
        stdinFd = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        stdinWriteLock.unlock()
    }

    /// Blocks until the task has fully finished (group swept, pipes drained, result delivered to the callback queue).
    @discardableResult
    public func waitUntilFinished(timeout: TimeInterval) -> Bool {
        return doneGroup.wait(timeout: .now() + timeout) == .success
    }

    public func cancel() {
        lock.lock()
        let already = cancelRequested
        cancelRequested = true
        lock.unlock()
        if already { return }
        terminate()
    }

    func markReady(pid reported: Int, pgid: Int) {
        lock.lock()
        if reported == Int(pid), pgid == Int(pid), ownsGroup {
            readyHandshake = true
            if gracefulPending, !cancelRequested, !leaderReaped {
                gracefulPending = false
                gracefulSent = kill(pid, SIGUSR1) == 0
            }
        }
        lock.unlock()
    }

    private func timeoutFired() {
        lock.lock()
        timedOutFlag = true
        lock.unlock()
        cancel()
    }

    /// SIGTERM now, SIGKILL after a grace period if the group is still around.
    private func terminate() {
        signalGroup(SIGTERM)
        Thread.detachNewThread { [weak self] in
            var waited = 0
            while waited < 60 {   // 1.5 s in 25 ms steps
                guard let self = self else { return }
                if self.isGroupGoneOrNotSpawned { return }
                usleep(25_000)
                waited += 1
            }
            self?.signalGroup(SIGKILL)
        }
    }

    private var isGroupGoneOrNotSpawned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return groupGone || finished
    }

    private func signalGroup(_ sig: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard pid > 0, !groupGone else { return }
        if ownsGroup {
            _ = kill(-pid, sig)
        } else if !leaderReaped {
            _ = kill(pid, sig)
        }
    }

    // MARK: Launch

    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        inheritedFileDescriptors: [Int32] = [],
        onDiagnosticLine: ((String) -> Void)? = nil,
        stdinData: Data?,
        timeout: TimeInterval?,
        onStdoutChunk: ((Data) -> Void)? = nil,
        onLine: @escaping (String) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) {
        Thread.detachNewThread { [self] in
            let result = self.runBlocking(
                executable: executable, arguments: arguments, environment: environment,
                workingDirectory: workingDirectory,
                inheritedFileDescriptors: inheritedFileDescriptors,
                onDiagnosticLine: onDiagnosticLine,
                stdinData: stdinData, timeout: timeout, onStdoutChunk: onStdoutChunk, onLine: onLine)
            self.lock.lock()
            self.finished = true
            self.lock.unlock()
            DispatchQueue.main.async {
                onExit(result)
                self.doneGroup.leave()
            }
        }
    }

    private func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        inheritedFileDescriptors: [Int32] = [],
        onDiagnosticLine: ((String) -> Void)? = nil,
        stdinData: Data?,
        timeout: TimeInterval?,
        onStdoutChunk: ((Data) -> Void)? = nil,
        onLine: @escaping (String) -> Void
    ) -> EngineTaskResult {
        var result = EngineTaskResult()

        lock.lock()
        let cancelledEarly = cancelRequested
        lock.unlock()
        if cancelledEarly {
            result.cancelled = true
            result.groupClean = true
            result.pipesDrained = true
            return result
        }

        var inP: [Int32] = [-1, -1], outP: [Int32] = [-1, -1], errP: [Int32] = [-1, -1]
        guard pipe(&inP) == 0, pipe(&outP) == 0, pipe(&errP) == 0 else {
            result.spawnError = "pipe 생성 실패 (errno \(errno))"
            return result
        }
        for fd in inP + outP + errP { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(inP[1], F_SETNOSIGPIPE, 1)

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fileActions, outP[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errP[1], 2)
        if let cwd = workingDirectory {
            let chdirRes = posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
            if chdirRes != 0 {
                posix_spawn_file_actions_destroy(&fileActions)
                close(inP[0]); close(inP[1])
                close(outP[0]); close(outP[1])
                close(errP[0]); close(errP[1])
                result.spawnError = "chdir failed (\(chdirRes))"
                return result
            }
        }
        for fd in inheritedFileDescriptors {
            if fd <= 2 {
                posix_spawn_file_actions_destroy(&fileActions)
                close(inP[0]); close(inP[1])
                close(outP[0]); close(outP[1])
                close(errP[0]); close(errP[1])
                result.spawnError = "invalid inherited fd \(fd)"
                return result
            }
            let inheritRes = posix_spawn_file_actions_addinherit_np(&fileActions, fd)
            if inheritRes != 0 {
                posix_spawn_file_actions_destroy(&fileActions)
                close(inP[0]); close(inP[1])
                close(outP[0]); close(outP[1])
                close(errP[0]); close(errP[1])
                result.spawnError = "addinherit failed (\(inheritRes))"
                return result
            }
        }

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        // SETPGROUP 0x2 | SETSIGDEF 0x4 | SETSIGMASK 0x8 | CLOEXEC_DEFAULT 0x4000
        posix_spawnattr_setflags(&attr, Int16(0x2 | 0x4 | 0x8 | 0x4000))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let argvStrings = [executable] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, executable, &fileActions, &attr, &argv, &envp)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        close(inP[0]); close(outP[1]); close(errP[1])

        guard rc == 0 else {
            close(inP[1]); close(outP[0]); close(errP[0])
            result.spawnError = "엔진 프로세스 실행 실패 (코드 \(rc))"
            return result
        }

        lock.lock()
        pid = childPid
        ownsGroup = (getpgid(childPid) == childPid)
        let cancelNow = cancelRequested
        lock.unlock()
        if cancelNow { terminate() }

        // Request payload goes through stdin so the address never appears in `ps` output.
        let writer = DispatchGroup()
        writer.enter()
        if keepStdinOpen {
            lock.lock(); stdinFd = inP[1]; lock.unlock()
            Thread.detachNewThread { [self] in
                if let data = stdinData { self.sendLine(data) }
                writer.leave()
            }
        } else {
            Thread.detachNewThread {
                if let data = stdinData {
                    data.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = write(inP[1], raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
                        }
                    }
                }
                close(inP[1])
                writer.leave()
            }
        }

        let stopReading = AtomicFlag()
        let readers = DispatchGroup()
        let stderrCount = AtomicCounter()

        readers.enter()
        Thread.detachNewThread { [self] in
            var lineBuffer = Data()
            var discarding = false
            let maxLine = 1 << 20
            Self.drain(fd: outP[0], stop: stopReading) { chunk in
                if let onStdoutChunk = onStdoutChunk {
                    // Raw path: bytes are delivered unchanged (no newline framing, trimming or handshake); draining continues to EOF.
                    onStdoutChunk(Data(chunk))
                    return
                }
                for byte in chunk {
                    if byte == 0x0A {
                        if !discarding, let line = String(data: lineBuffer, encoding: .utf8) {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { self.dispatchLine(trimmed, onLine: onLine) }
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                        discarding = false
                    } else if !discarding {
                        if lineBuffer.count >= maxLine {
                            discarding = true
                            lineBuffer.removeAll(keepingCapacity: true)
                        } else {
                            lineBuffer.append(byte)
                        }
                    }
                }
            }
            close(outP[0])
            readers.leave()
        }

        readers.enter()
        Thread.detachNewThread {
            if let onDiag = onDiagnosticLine {
                var buffer = Data()
                let maxLineBytes = 16 * 1024
                let maxTotalBytes = 64 * 1024
                var totalBytesDispatched = 0
                Self.drain(fd: errP[0], stop: stopReading) { chunk in
                    stderrCount.add(chunk.count)
                    if totalBytesDispatched < maxTotalBytes {
                        let remaining = maxTotalBytes - totalBytesDispatched
                        let toAppend = chunk.prefix(remaining)
                        buffer.append(contentsOf: toAppend)
                        totalBytesDispatched += toAppend.count
                        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = buffer.subdata(in: 0..<newlineIndex)
                            buffer.removeSubrange(0...newlineIndex)
                            let lineToEmit = lineData.prefix(maxLineBytes)
                            if let lineStr = String(data: lineToEmit, encoding: .utf8) {
                                onDiag(lineStr)
                            }
                        }
                    }
                }
                if !buffer.isEmpty && totalBytesDispatched <= maxTotalBytes {
                    let lineToEmit = buffer.prefix(maxLineBytes)
                    if let lineStr = String(data: lineToEmit, encoding: .utf8) {
                        onDiag(lineStr)
                    }
                }
            } else {
                // stderr is drained and counted only; raw text (it may contain URLs) is never retained or shown.
                Self.drain(fd: errP[0], stop: stopReading) { chunk in stderrCount.add(chunk.count) }
            }
            close(errP[0])
            readers.leave()
        }

        if let timeout = timeout {
            Thread.detachNewThread { [weak self] in
                let end = Date().addingTimeInterval(timeout)
                while Date() < end {
                    usleep(50_000)
                    guard let self = self else { return }
                    if self.isFinishedOrReaped { return }
                }
                self?.timeoutFired()
            }
        }

        // Reap the leader (only here).
        var status: Int32 = 0
        while true {
            let r = waitpid(childPid, &status, 0)
            if r == childPid { break }
            if r < 0 && errno == EINTR { continue }
            break
        }
        lock.lock()
        leaderReaped = true
        let wasCancelled = cancelRequested
        let timedOut = timedOutFlag
        let owned = ownsGroup
        lock.unlock()
        if keepStdinOpen { closeStdin() }

        // Sweep whatever the leader left behind (also on normal exit).
        let clean = sweepGroup(owned: owned, pgid: childPid)

        // Pipes must reach EOF once all writers are gone; do not hang forever if something escaped the group.
        let drained = readers.wait(timeout: .now() + 3.0) == .success
        if !drained {
            stopReading.set()
            _ = readers.wait(timeout: .now() + 2.0)
        }
        _ = writer.wait(timeout: .now() + 1.0)

        lock.lock()
        let ready = readyHandshake
        lock.unlock()

        let termSig = status & 0x7f
        if termSig == 0 {
            result.exitCode = (status >> 8) & 0xff
        } else if termSig != 0x7f {
            result.terminatedBySignal = termSig
        }
        result.cancelled = wasCancelled
        result.timedOut = timedOut
        result.groupClean = clean
        result.pipesDrained = drained
        result.readyHandshake = ready
        result.stderrBytes = stderrCount.value
        return result
    }

    private var isFinishedOrReaped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return leaderReaped || finished
    }

    private func sweepGroup(owned: Bool, pgid: pid_t) -> Bool {
        guard owned else {
            lock.lock(); groupGone = true; lock.unlock()
            return true
        }
        func alive() -> Bool {
            if kill(-pgid, 0) == 0 { return true }
            return errno == EPERM
        }
        if !alive() {
            lock.lock(); groupGone = true; lock.unlock()
            return true
        }
        signalGroup(SIGTERM)
        for _ in 0..<60 where alive() { usleep(25_000) }
        if alive() {
            signalGroup(SIGKILL)
            for _ in 0..<200 where alive() { usleep(25_000) }
        }
        let gone = !alive()
        if gone {
            lock.lock(); groupGone = true; lock.unlock()
        }
        return gone
    }

    private func dispatchLine(_ line: String, onLine: (String) -> Void) {
        // Handshake is consumed here; everything else goes to the caller.
        if line.contains("\"ready\""),
           let data = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["event"] as? String) == "ready",
           let payload = json["payload"] as? [String: Any],
           let p = (payload["pid"] as? NSNumber)?.intValue,
           let g = (payload["pgid"] as? NSNumber)?.intValue {
            markReady(pid: p, pgid: g)
            return
        }
        onLine(line)
    }

    private static func drain(fd: Int32, stop: AtomicFlag, handle: (UnsafeBufferPointer<UInt8>) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 100)
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if pr == 0 {
                if stop.value { break }
                continue
            }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                buffer.withUnsafeBufferPointer { handle(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            } else if n == 0 {
                break
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                break
            }
        }
    }
}

final class AtomicFlag {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

final class AtomicCounter {
    private var count = 0
    private let lock = NSLock()
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
}

public final class EngineBridge {
    public static let shared = EngineBridge()

    private let registryLock = NSLock()
    private var live: [ObjectIdentifier: EngineTaskHandle] = [:]

    private init() {}

    public func findPythonExecutable() -> String {
        let candidates = [
            "/opt/homebrew/Cellar/yt-dlp/2026.10.21/libexec/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "/usr/bin/python3"
    }

    public func findEngineScript() -> String? {
        if let bundleRes = Bundle.main.resourceURL?.appendingPathComponent("engine.py").path,
           FileManager.default.fileExists(atPath: bundleRes) {
            return bundleRes
        }
        let cwd = FileManager.default.currentDirectoryPath
        let localCandidate = (cwd as NSString).appendingPathComponent("Engine/engine.py")
        if FileManager.default.fileExists(atPath: localCandidate) {
            return localCandidate
        }
        return nil
    }

    // MARK: Portable runtime (Resources/EngineRuntime/htd-engine + _internal/tools)

    public enum RuntimeMode: String {
        /// The frozen engine inside the app's own Resources, structurally validated.
        case bundled
        /// No EngineRuntime in the app: the development Python + engine.py stack.
        case development
        /// An EngineRuntime exists but is incomplete or unsafe: nothing runs (no silent switch to the external stack).
        case invalid
    }

    struct EngineLaunchError: Error {
        let message: String
    }

    private static let requiredBundledTools = ["ffmpeg", "ffprobe", "deno"]

    private func lstatMode(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? (st.st_mode & S_IFMT) : nil
    }

    private func isRealDirectory(_ path: String) -> Bool { lstatMode(path) == S_IFDIR }

    private func isRegularExecutable(_ path: String) -> Bool {
        lstatMode(path) == S_IFREG && access(path, X_OK) == 0
    }

    /// Decides once per call which engine this app runs. Every path is derived from the app's own Resources
    /// directory (never from job or user context) and must be a real, non-symlink entry that stays inside it.
    public func runtimeResolution() -> (mode: RuntimeMode, executable: String?) {
        guard let resources = Bundle.main.resourceURL?.path else { return (.development, nil) }
        let runtime = resources + "/EngineRuntime"
        var st = stat()
        if lstat(runtime, &st) != 0 {
            return errno == ENOENT ? (.development, nil) : (.invalid, nil)
        }
        let executable = runtime + "/htd-engine"
        let tools = runtime + "/_internal/tools"
        guard isRealDirectory(runtime), isRealDirectory(runtime + "/_internal"),
              isRealDirectory(tools), isRegularExecutable(executable),
              Self.requiredBundledTools.allSatisfy({ isRegularExecutable(tools + "/" + $0) }) else {
            return (.invalid, nil)
        }
        let realResources = URL(fileURLWithPath: resources).resolvingSymlinksInPath().path
        let realExecutable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard realExecutable.hasPrefix(realResources + "/EngineRuntime/") else { return (.invalid, nil) }
        return (.bundled, executable)
    }

    /// "bundled" | "development" | "invalid" (diagnostics: a fixed vocabulary).
    public var runtimeModeName: String { runtimeResolution().mode.rawValue }

    /// Executable + full argument list for one engine command: the bundled engine first, the development
    /// Python + script only when the app carries no EngineRuntime at all, and an honest failure otherwise.
    func engineInvocation(_ arguments: [String]) -> Result<(executable: String, arguments: [String]), EngineLaunchError> {
        let resolved = runtimeResolution()
        switch resolved.mode {
        case .bundled:
            return .success((resolved.executable ?? "", arguments))
        case .invalid:
            return .failure(EngineLaunchError(
                message: "내장 엔진 구성이 손상되었거나 안전하지 않아 실행하지 않았습니다. 앱을 다시 설치해 주세요."))
        case .development:
            guard let script = findEngineScript() else {
                return .failure(EngineLaunchError(message: "엔진 스크립트(engine.py)를 찾을 수 없습니다."))
            }
            return .success((findPythonExecutable(), [script] + arguments))
        }
    }

    private func engineEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["NO_COLOR"] = "1"
        return env
    }

    // MARK: Registry (used on app quit)

    private func register(_ h: EngineTaskHandle) {
        registryLock.lock(); live[ObjectIdentifier(h)] = h; registryLock.unlock()
    }

    private func unregister(_ h: EngineTaskHandle) {
        registryLock.lock(); live[ObjectIdentifier(h)] = nil; registryLock.unlock()
    }

    public var liveTaskCount: Int {
        registryLock.lock(); defer { registryLock.unlock() }
        return live.count
    }

    /// Cancels every running engine and waits (bounded) until their process groups are gone.
    @discardableResult
    public func terminateAll(timeout: TimeInterval) -> Bool {
        registryLock.lock()
        let handles = Array(live.values)
        registryLock.unlock()
        handles.forEach { $0.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        var all = true
        for h in handles {
            let remaining = max(0.1, deadline.timeIntervalSinceNow)
            // The completion hop uses the main queue; when we are on it, spin the run loop instead of blocking it.
            if Thread.isMainThread {
                while !h.isFinished && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
                if !h.isFinished { all = false }
            } else if !h.waitUntilFinished(timeout: remaining) {
                all = false
            }
        }
        return all
    }

    // MARK: Generic launcher (also used by probes with arbitrary executables)

    func launch(
        jobId: String,
        generation: Int,
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        inheritedFileDescriptors: [Int32] = [],
        onDiagnosticLine: ((String) -> Void)? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        keepStdinOpen: Bool = false,
        onStdoutChunk: ((Data) -> Void)? = nil,
        onLine: @escaping (String) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) -> EngineTaskHandle {
        let handle = EngineTaskHandle(jobId: jobId, generation: generation, keepStdinOpen: keepStdinOpen)
        register(handle)
        handle.launch(
            executable: executable, arguments: arguments,
            environment: environment ?? engineEnvironment(),
            workingDirectory: workingDirectory,
            inheritedFileDescriptors: inheritedFileDescriptors,
            onDiagnosticLine: onDiagnosticLine,
            stdinData: stdinData, timeout: timeout, onStdoutChunk: onStdoutChunk, onLine: onLine,
            onExit: { [weak self] result in
                self?.unregister(handle)
                onExit(result)
            })
        return handle
    }

    // MARK: Health

    public func checkHealth(completion: @escaping (EngineHealthStatus) -> Void) {
        var status = EngineHealthStatus()
        status.lastChecked = Date()
        status.pythonPath = findPythonExecutable()
        let invocation: (executable: String, arguments: [String])
        switch engineInvocation(["health"]) {
        case .success(let value):
            invocation = value
        case .failure(let error):
            status.checked = true
            status.failureReason = error.message
            DispatchQueue.main.async { completion(status) }
            return
        }
        status.pythonPath = invocation.executable
        var collected = status
        _ = launch(
            jobId: "", generation: 0,
            executable: invocation.executable, arguments: invocation.arguments,
            timeout: 30,
            onLine: { line in
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["event"] as? String) == "health",
                      let p = json["payload"] as? [String: Any] else { return }
                DispatchQueue.main.async {
                    collected.healthy = p["healthy"] as? Bool ?? false
                    collected.pythonVersion = p["python_version"] as? String ?? ""
                    collected.ytdlpAvailable = p["ytdlp_available"] as? Bool ?? false
                    collected.ytdlpVersion = p["ytdlp_version"] as? String ?? ""
                    collected.ffmpegAvailable = p["ffmpeg_available"] as? Bool ?? false
                    collected.ffmpegPath = p["ffmpeg_path"] as? String
                    collected.ffmpegVersion = p["ffmpeg_version"] as? String ?? ""
                    collected.ffprobeAvailable = p["ffprobe_available"] as? Bool ?? false
                    collected.ffprobePath = p["ffprobe_path"] as? String
                    collected.denoAvailable = p["deno_available"] as? Bool ?? false
                    collected.denoPath = p["deno_path"] as? String
                    collected.denoVersion = p["deno_version"] as? String ?? ""
                    collected.ejsAvailable = p["ejs_available"] as? Bool ?? false
                    collected.engineType = p["engine_type"] as? String ?? collected.engineType
                    collected.checked = true
                }
            },
            onExit: { result in
                if !collected.checked {
                    collected.checked = true
                    collected.healthy = false
                    collected.failureReason = result.timedOut ? "엔진 상태 확인이 시간 초과되었습니다."
                        : (result.spawnError ?? "엔진 상태 응답을 받지 못했습니다.")
                }
                completion(collected)
            })
    }

    // MARK: Extraction / download

    /// `context` (proxy URL with session credentials, scoped login cookies) travels only inside the stdin request.
    public func extractInfo(
        jobId: String,
        generation: Int,
        url: String,
        context: [String: Any] = [:],
        onEvent: @escaping (String, [String: Any]) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) -> EngineTaskHandle {
        return runEngine(command: "extract", jobId: jobId, generation: generation,
                         request: ["url": url, "context": context], onEvent: onEvent, onExit: onExit)
    }

    public func startDownload(
        jobId: String,
        generation: Int,
        url: String,
        spec: [String: Any],
        context: [String: Any] = [:],
        onEvent: @escaping (String, [String: Any]) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) -> EngineTaskHandle {
        return runEngine(command: "download", jobId: jobId, generation: generation,
                         request: ["url": url, "spec": spec, "context": context], onEvent: onEvent, onExit: onExit)
    }

    /// Live recording. Hard timeout = chosen bound + margin, so a stuck stream can never run forever.
    public func startRecording(
        jobId: String,
        generation: Int,
        url: String,
        spec: [String: Any],
        context: [String: Any] = [:],
        limitSeconds: Int,
        onEvent: @escaping (String, [String: Any]) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) -> EngineTaskHandle {
        return runEngine(command: "record", jobId: jobId, generation: generation,
                         request: ["url": url, "spec": spec, "context": context],
                         timeout: TimeInterval(limitSeconds + 900), onEvent: onEvent, onExit: onExit)
    }

    /// User-started speed check (Engine/speed.py, fixed Cloudflare endpoints). The request carries no address, only
    /// the optional proxy context; the engine bounds itself to ~25 s, the hard timeout is a safety net.
    public func startSpeedTest(
        generation: Int,
        context: [String: Any],
        onEvent: @escaping (String, [String: Any]) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) -> EngineTaskHandle {
        return runEngine(command: "speed", jobId: "speed-test", generation: generation, request: ["context": context],
                         timeout: 45, onEvent: onEvent, onExit: onExit)
    }

    /// Connection-assist proxy helper. `config` is the first stdin line; the pipe stays open for policy updates.
    public func startProxy(
        config: [String: Any],
        onEvent: @escaping (String, [String: Any]) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) -> EngineTaskHandle {
        return runEngine(command: "proxy", jobId: "connection-assist", generation: 1, request: config,
                         keepStdinOpen: true, onEvent: onEvent, onExit: onExit)
    }

    private func runEngine(
        command: String,
        jobId: String,
        generation: Int,
        request: [String: Any],
        timeout: TimeInterval? = nil,
        keepStdinOpen: Bool = false,
        onEvent: @escaping (String, [String: Any]) -> Void,
        onExit: @escaping (EngineTaskResult) -> Void
    ) -> EngineTaskHandle {
        let plan = engineInvocation([command, "--job-id", jobId, "--generation", "\(generation)"])
        guard case .success(let invocation) = plan,
              let body = try? JSONSerialization.data(withJSONObject: request) else {
            let handle = EngineTaskHandle(jobId: jobId, generation: generation)
            var r = EngineTaskResult()
            if case .failure(let error) = plan {
                r.spawnError = error.message
            } else {
                r.spawnError = "엔진 요청을 직렬화하지 못했습니다."
            }
            DispatchQueue.main.async {
                onExit(r)
                handle.markFinishedWithoutProcess()
            }
            return handle
        }
        return launch(
            jobId: jobId, generation: generation,
            executable: invocation.executable,
            arguments: invocation.arguments,
            stdinData: body,
            timeout: timeout,
            keepStdinOpen: keepStdinOpen,
            onLine: { line in
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                // Strict rejection of events that do not belong to this job generation.
                guard (json["jobID"] as? String) == jobId,
                      (json["generation"] as? NSNumber)?.intValue == generation else { return }
                let event = json["event"] as? String ?? ""
                let payload = json["payload"] as? [String: Any] ?? [:]
                DispatchQueue.main.async { onEvent(event, payload) }
            },
            onExit: onExit)
    }
}

extension EngineTaskHandle {
    fileprivate func markFinishedWithoutProcess() {
        lock.lock()
        finished = true
        lock.unlock()
        doneGroup.leave()
    }
}

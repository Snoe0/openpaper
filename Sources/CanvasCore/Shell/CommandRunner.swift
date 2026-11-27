import Foundation

/// How a finished command went: its exit status and everything it printed.
public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs an executable with an argument vector (never through a shell string) and waits for it.
public protocol CommandRunning: Sendable {
    /// `environment` nil inherits the app's environment. Throws `CommandTimedOut` when the command
    /// hasn't finished by `timeout`.
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> CommandResult
}

/// A command ran past its deadline and was stopped.
public struct CommandTimedOut: Error, Equatable {
    public init() {}
}

/// Runs commands with `Process` on a background queue. At the deadline the command gets SIGTERM,
/// then SIGKILL if it lingers, and reading from its pipes stops (they close once released), so
/// neither it nor a child that inherited them can keep the caller waiting.
public struct ProcessRunner: CommandRunning {
    /// How long a terminated command gets before it is killed.
    private static let gracePeriod: DispatchTimeInterval = .seconds(1)
    /// How long output may keep arriving after the command exits (from children that inherited its pipes).
    private static let drainPeriod: DispatchTimeInterval = .seconds(1)

    public init() {}

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runAndWait(executable, arguments, environment: environment, timeout: timeout) })
            }
        }
    }

    private static func runAndWait(_ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: Duration) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let output = PipeReader(), errors = PipeReader()
        process.standardOutput = output.pipe
        process.standardError = errors.pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            output.close()
            errors.close()
            throw error
        }

        guard exited.wait(timeout: .now() + timeout.timeInterval) == .success else {
            // Only the command itself is stopped: anything it started (e.g. a login shell's
            // grandchildren) may outlive it, still holding the pipes, which is why reading stops here.
            stop(process, exited: exited)
            output.close()
            errors.close()
            throw CommandTimedOut()
        }
        let drained = DispatchTime.now() + drainPeriod
        return CommandResult(status: process.terminationStatus, stdout: output.text(by: drained), stderr: errors.text(by: drained))
    }

    /// SIGTERM, then SIGKILL after a grace period.
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        guard exited.wait(timeout: .now() + gracePeriod) == .timedOut, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + gracePeriod)
    }
}

/// Collects a pipe's output as it arrives, without blocking a thread on it.
/// Unchecked Sendable: `data` and `isClosed` are only touched under `lock`.
private final class PipeReader: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    private var isClosed = false
    private let finished = DispatchSemaphore(value: 0)

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { return self.close(signalling: true) }
            self.lock.withLock { self.data.append(chunk) }
        }
    }

    /// What arrived until end of file, or until `deadline` if the pipe stays open.
    func text(by deadline: DispatchTime) -> String {
        _ = finished.wait(timeout: deadline)
        close()
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }

    func close() {
        close(signalling: false)
    }

    private func close(signalling: Bool) {
        let wasOpen = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        guard wasOpen else { return }
        // Stops reading; the descriptor itself closes when the pipe is released, which can't race a
        // handler call that is still running.
        pipe.fileHandleForReading.readabilityHandler = nil
        if signalling { finished.signal() }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

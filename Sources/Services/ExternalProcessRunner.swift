import Foundation
import Darwin

enum ExternalProcessRunnerError: LocalizedError, Equatable {
    case missingExecutable(String)
    case missingWorkingDirectory(String)
    case failedToLaunch(String)
    case timedOut(String, TimeInterval, stdout: Data, stderr: Data)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            "Missing executable: \(path)"
        case .missingWorkingDirectory(let path):
            "Missing working directory: \(path)"
        case .failedToLaunch(let message):
            "Failed to launch process: \(message)"
        case .timedOut(let command, let timeout, let stdout, let stderr):
            "Process timed out after \(timeout)s: \(command) (stdout \(stdout.count) bytes, stderr \(stderr.count) bytes)"
        }
    }
}

final class ExternalProcessRunner: ExternalProcessRunning, @unchecked Sendable {
    func run(_ request: ExternalProcessRequest) async throws -> ExternalProcessResult {
        await Task.yield()

        let executableURL = URL(fileURLWithPath: request.executablePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ExternalProcessRunnerError.missingExecutable(executableURL.path)
        }

        if let workingDirectory = request.workingDirectory,
           !FileManager.default.fileExists(atPath: workingDirectory.path) {
            throw ExternalProcessRunnerError.missingWorkingDirectory(workingDirectory.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory

        var environment = ProcessInfo.processInfo.environment
        request.environment.forEach { key, value in
            environment[key] = value
        }
        for key in environment.keys where key.hasPrefix("DYLD_") || key.hasPrefix("__XPC_DYLD_") {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }
        let stdoutAccumulator = DataAccumulator()
        let stderrAccumulator = DataAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutAccumulator.append(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrAccumulator.append(chunk)
            if let callback = request.onStderrChunk {
                Task {
                    await callback(chunk)
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw ExternalProcessRunnerError.failedToLaunch(error.localizedDescription)
        }

        let commandLine = renderCommandLine(executablePath: request.executablePath, arguments: request.arguments)
        let timedOut = waitForExit(
            process: process,
            timeout: request.timeout,
            terminationSemaphore: terminationSemaphore
        )
        if timedOut {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            let didTerminate = waitForTerminationSignal(terminationSemaphore, timeout: 1)
            if !didTerminate, process.isRunning {
                forceKill(process)
                _ = waitForTerminationSignal(terminationSemaphore, timeout: 1)
            }
            let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !stdoutTail.isEmpty {
                stdoutAccumulator.append(stdoutTail)
            }
            if !stderrTail.isEmpty {
                stderrAccumulator.append(stderrTail)
            }
            throw ExternalProcessRunnerError.timedOut(
                commandLine,
                request.timeout,
                stdout: stdoutAccumulator.snapshot(),
                stderr: stderrAccumulator.snapshot()
            )
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !stdoutTail.isEmpty {
            stdoutAccumulator.append(stdoutTail)
        }
        if !stderrTail.isEmpty {
            stderrAccumulator.append(stderrTail)
        }
        process.terminationHandler = nil
        return ExternalProcessResult(
            stdout: stdoutAccumulator.snapshot(),
            stderr: stderrAccumulator.snapshot(),
            exitCode: process.terminationStatus
        )
    }

    private func waitForExit(
        process: Process,
        timeout: TimeInterval,
        terminationSemaphore: DispatchSemaphore
    ) -> Bool {
        guard timeout > 0 else {
            terminationSemaphore.wait()
            return false
        }

        let waitResult = terminationSemaphore.wait(timeout: .now() + timeout)
        if waitResult == .success {
            return false
        }

        if process.isRunning {
            return true
        }

        return false
    }

    private func waitForTerminationSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        guard timeout > 0 else {
            semaphore.wait()
            return true
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    private func forceKill(_ process: Process) {
        guard process.processIdentifier > 0 else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private func renderCommandLine(executablePath: String, arguments: [String]) -> String {
        ([executablePath] + arguments)
            .map { value in
                if value.contains(" ") || value.contains("\t") {
                    return "\"\(value)\""
                }
                return value
            }
            .joined(separator: " ")
    }
}

private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}

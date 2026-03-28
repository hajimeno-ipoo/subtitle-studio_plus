@testable import SubtitleStudioPlus
import Foundation
import Testing

struct ExternalProcessRunnerTests {
    @Test
    func definesExternalProcessRequestContract() {
        let request = ExternalProcessRequest(
            executablePath: "/bin/echo",
            arguments: ["hello", "world"],
            workingDirectory: nil,
            environment: ["A": "B"],
            timeout: 3.5
        )

        #expect(request.executablePath == "/bin/echo")
        #expect(request.arguments == ["hello", "world"])
        #expect(request.workingDirectory == nil)
        #expect(request.environment["A"] == "B")
        #expect(request.timeout == 3.5)
    }

    @Test
    func definesExternalProcessResultContract() {
        let result = ExternalProcessResult(
            stdout: Data("out".utf8),
            stderr: Data("err".utf8),
            exitCode: 7
        )

        #expect(String(data: result.stdout, encoding: .utf8) == "out")
        #expect(String(data: result.stderr, encoding: .utf8) == "err")
        #expect(result.exitCode == 7)
    }

    @Test
    func implementsProcessExecutionEssentials() async throws {
        let runner = ExternalProcessRunner()
        let request = ExternalProcessRequest(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "printf foo; sleep 0.05; printf bar >&2; exit 7"
            ],
            workingDirectory: nil,
            environment: [:],
            timeout: 5
        )

        let result = try await runner.run(request)

        #expect(String(data: result.stdout, encoding: .utf8) == "foo")
        #expect(String(data: result.stderr, encoding: .utf8) == "bar")
        #expect(result.exitCode == 7)
    }

    @Test
    func capturesPartialOutputWhenTimedOut() async throws {
        let runner = ExternalProcessRunner()
        let request = ExternalProcessRequest(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "printf foo; sleep 0.05; printf bar >&2; sleep 2"
            ],
            workingDirectory: nil,
            environment: [:],
            timeout: 0.5
        )

        do {
            _ = try await runner.run(request)
            #expect(Bool(false))
        } catch let error as ExternalProcessRunnerError {
            switch error {
            case let .timedOut(command, timeout, stdout, stderr):
                #expect(command.contains("/bin/sh"))
                #expect(timeout == 0.5)
                #expect(String(data: stdout, encoding: .utf8) == "foo")
                #expect(String(data: stderr, encoding: .utf8) == "bar")
            default:
                #expect(Bool(false))
            }
        }
    }

    @Test
    func doesNotReportTimeoutAfterProcessAlreadyExited() async throws {
        let runner = ExternalProcessRunner()
        let request = ExternalProcessRequest(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "sleep 0.1; printf ok"
            ],
            workingDirectory: nil,
            environment: [:],
            timeout: 5
        )

        let result = try await runner.run(request)

        #expect(String(data: result.stdout, encoding: .utf8) == "ok")
        #expect(result.exitCode == 0)
    }
}

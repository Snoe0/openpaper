import XCTest
@testable import CanvasCore

final class ShellProcessRunnerTests: XCTestCase {
    func testTheProcessRunnerCapturesStatusAndBothStreams() async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "printf out; printf '%s %s' \"$1\" \"$X\" >&2; exit 3", "sh", "err $X"],
            environment: ["X": "42"], timeout: .seconds(10)
        )

        // The argument arrives literally (no shell expansion); the environment is applied.
        XCTAssertEqual(result, CommandResult(status: 3, stdout: "out", stderr: "err $X 42"))
    }

    func testTheProcessRunnerThrowsForAMissingExecutable() async {
        do {
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/no/such/tool"), [], environment: nil, timeout: .seconds(5))
            XCTFail("expected an error")
        } catch {}
    }

    func testTheProcessRunnerStopsACommandAtItsDeadline() async {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: nil, timeout: .milliseconds(300))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is CommandTimedOut, "unexpected error \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testTheProcessRunnerKillsACommandThatIgnoresTermination() async {
        // The shell ignores SIGTERM, and its child keeps the output pipes open after the shell dies.
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; /bin/sleep 30; /bin/sleep 30"], environment: nil, timeout: .milliseconds(300))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is CommandTimedOut, "unexpected error \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(8))
    }

    func testOutputArrivesEvenWhenABackgroundChildKeepsThePipesOpen() async throws {
        let start = ContinuousClock.now

        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", "/bin/sleep 30 & echo hi"], environment: nil, timeout: .seconds(10))

        XCTAssertEqual(result, CommandResult(status: 0, stdout: "hi\n", stderr: ""))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }
}

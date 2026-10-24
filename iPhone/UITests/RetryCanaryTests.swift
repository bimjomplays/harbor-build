import XCTest

/// Shows how ios.yml reports a test that only passed on its retry. On a run dispatched with
/// `flaky_canary`, ios.yml hands the runner HARBOR_FLAKY_CANARY=1 (as TEST_RUNNER_HARBOR_FLAKY_CANARY):
/// this test then fails its first try on purpose and passes the retry, so the run summary and the
/// annotations carry one "passed on retry" entry. Every other run skips it.
final class RetryCanaryTests: XCTestCase {
    func testFailsOnceThenPassesOnRetry() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HARBOR_FLAKY_CANARY"] == "1" else {
            throw XCTSkip("runs only when ios.yml is dispatched with flaky_canary")
        }
        // The first try leaves a marker; the retry (a second xcodebuild run, a fresh runner process) finds it. Kept in the
        // runner's temporary directory and, when ios.yml names one, in a directory on the runner host.
        let name = "harbor-flaky-canary-\(env["HARBOR_CANARY_RUN"] ?? "local")"
        var dirs = [FileManager.default.temporaryDirectory]
        if let dir = env["HARBOR_CANARY_DIR"], !dir.isEmpty { dirs.insert(URL(fileURLWithPath: dir), at: 0) }
        let markers = dirs.map { $0.appendingPathComponent(name) }
        if markers.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { return }
        for marker in markers { try? Data().write(to: marker) }
        XCTFail("flaky canary: the first try fails on purpose, the retry passes")
    }
}

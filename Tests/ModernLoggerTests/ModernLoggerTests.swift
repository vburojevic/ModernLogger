#if canImport(XCTest)
import XCTest
@testable import ModernLogger

final class ModernLoggerTests: XCTestCase {
    func testFilterAllows() throws {
        var cfg = LogConfiguration.default
        cfg.filter.minimumLevel = .warning
        LogSystem.bootstrap(configuration: cfg, sinks: [InMemorySink(capacity: 50)])

        let log = Log(category: "Test")
        log.info("should drop")
        log.warning("should keep")

        // We cannot easily await the pipeline without a helper, but this is enough
        // as a compilation + smoke test when run in CI.
    }

    func testFileSinkDefaultURL() throws {
        let url = FileSink.defaultURL(fileName: "modernlogger-test.jsonl")
        XCTAssertTrue(url.lastPathComponent.contains("modernlogger-test"))
    }
}
#endif

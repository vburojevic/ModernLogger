#if canImport(XCTest)
import XCTest
@testable import ModernSwiftLogger

final class ModernSwiftLoggerTests: XCTestCase {
    private struct TestError: Error {}
    private struct EnvSnapshot {
        let value: String?
    }

    func testFilterAllows() async throws {
        var cfg = LogConfiguration.default
        cfg.filter.minimumLevel = .warning
        let sink = TestSink()
        LogSystem.bootstrap(configuration: cfg, sinks: [sink])

        let log = Log(category: "Test")
        log.info("should drop")
        log.warning("should keep")

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.message, "should keep")
    }

    func testFileSinkDefaultURL() throws {
        let url = FileSink.defaultURL(fileName: "modernswiftlogger-test.jsonl")
        XCTAssertTrue(url.lastPathComponent.contains("modernswiftlogger-test"))
    }

    func testTagMinimumLevelOverrides() async throws {
        var cfg = LogConfiguration.default
        cfg.tagMinimumLevels = ["feature:Checkout": .error]
        let sink = TestSink()
        LogSystem.bootstrap(configuration: cfg, sinks: [sink])

        let log = Log(category: "Test")
        log.warning("warn", tags: [.feature("Checkout")])
        log.error("error", tags: [.feature("Checkout")])

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.level, .error)
    }

    func testMessageTruncation() async throws {
        var cfg = LogConfiguration.default
        cfg.maxMessageBytes = 5
        let sink = TestSink()
        LogSystem.bootstrap(configuration: cfg, sinks: [sink])

        let log = Log(category: "Test")
        log.info("1234567")

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertEqual(events.first?.message, "12345...(truncated)")
    }

    func testRedactionPatterns() async throws {
        var cfg = LogConfiguration.default
        cfg.redactedMetadataKeys = ["password", "auth.*", "*.token"]
        let sink = TestSink()
        LogSystem.bootstrap(configuration: cfg, sinks: [sink])

        let log = Log(category: "Test")
        log.info("redact", metadata: [
            "password": .string("secret"),
            "auth": .object(["token": .string("abc")]),
            "nested": .object(["user": .object(["token": .string("xyz")])])
        ])

        await LogSystem.flush()
        let events = await sink.snapshot()
        guard let meta = events.first?.metadata else {
            XCTFail("missing metadata")
            return
        }

        if case .string(let value)? = meta["password"] {
            XCTAssertEqual(value, "<redacted>")
        } else {
            XCTFail("password not redacted")
        }

        if case .object(let auth)? = meta["auth"],
           case .string(let value)? = auth["token"] {
            XCTAssertEqual(value, "<redacted>")
        } else {
            XCTFail("auth.token not redacted")
        }

        if case .object(let nested)? = meta["nested"],
           case .object(let user)? = nested["user"],
           case .string(let value)? = user["token"] {
            XCTAssertEqual(value, "<redacted>")
        } else {
            XCTFail("nested.user.token not redacted")
        }
    }

    func testSinkSpecificRedaction() async throws {
        var cfg = LogConfiguration.default
        cfg.redactedMetadataKeys = []
        let sink = TestSink(redactionKeys: ["secret"])
        LogSystem.bootstrap(configuration: cfg, sinks: [sink])

        let log = Log(category: "Test")
        log.info("redact", metadata: ["secret": .string("value")])

        await LogSystem.flush()
        let events = await sink.snapshot()
        guard let meta = events.first?.metadata else {
            XCTFail("missing metadata")
            return
        }
        if case .string(let value)? = meta["secret"] {
            XCTAssertEqual(value, "<redacted>")
        } else {
            XCTFail("secret not redacted")
        }
    }

    func testUptimeNanosecondsPresent() async throws {
        let sink = TestSink()
        LogSystem.bootstrap(configuration: .default, sinks: [sink])
        Log(category: "Test").info("event")
        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertNotNil(events.first?.uptimeNanoseconds)
    }

    func testSinkErrorSnapshots() throws {
        LogSystem.clearSinkErrors()
        let handler = LogSystem.makeSinkErrorHandler(label: "TestSink")
        handler(TestError())
        handler(TestError())

        let snapshots = LogSystem.sinkErrorSnapshots()
        let snapshot = snapshots.first { $0.sink == "TestSink" }
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.count, 2)
        XCTAssertNotNil(snapshot?.lastTimestamp)
        XCTAssertNotNil(snapshot?.lastError)

        LogSystem.clearSinkErrors()
        XCTAssertTrue(LogSystem.sinkErrorSnapshots().isEmpty)
    }

    func testCategoryRateLimitDrops() async throws {
        var cfg = LogConfiguration.default
        cfg.categoryRateLimits = ["RateLimited": RateLimit(eventsPerSecond: 1, burst: 1)]
        let sink = TestSink()
        LogSystem.bootstrap(configuration: cfg, sinks: [sink])

        let log = Log(category: "RateLimited")
        log.info("first")
        log.info("second")

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
    }

    func testTagRateLimitDrops() async throws {
        var cfg = LogConfiguration.default
        cfg.tagRateLimits = ["feature:Limited": RateLimit(eventsPerSecond: 1, burst: 1)]
        let sink = TestSink()
        LogSystem.bootstrap(configuration: cfg, sinks: [sink])

        let log = Log(category: "Any")
        log.info("first", tags: [.feature("Limited")])
        log.info("second", tags: [.feature("Limited")])

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
    }

    func testFileSinkWrites() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("modernswiftlogger-\(UUID().uuidString).jsonl")
        let sink = FileSink(url: url, buffering: .init(maxBytes: 1, flushInterval: 0))
        LogSystem.bootstrap(configuration: .default, sinks: [sink])

        Log(category: "File").info("hello")
        await LogSystem.flush()

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"message\":\"hello\""))
        try? FileManager.default.removeItem(at: url)
    }

    func testFileSinkRotationAndCompression() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("modernswiftlogger-\(UUID().uuidString).jsonl")
        let rotation = FileSink.Rotation(maxBytes: 256 * 1024, maxFiles: 2, compression: .none)
        let sink = FileSink(url: url, rotation: rotation, buffering: .init(maxBytes: 4 * 1024, flushInterval: 0))
        LogSystem.bootstrap(configuration: .default, sinks: [sink])

        let log = Log(category: "Rotate")
        let payload = String(repeating: "x", count: 2048)
        for i in 0..<200 {
            log.info("line \(i) \(payload)")
        }
        await LogSystem.flush()

        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let rotated = items.filter { $0.lastPathComponent.hasPrefix(url.deletingPathExtension().lastPathComponent + "-") }
        let hasAnyRotation = !rotated.isEmpty
        XCTAssertTrue(hasAnyRotation)
        try? FileManager.default.removeItem(at: url)
        for item in rotated {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func testFileSinkRotationWithCompression() async throws {
        #if canImport(Compression)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("modernswiftlogger-\(UUID().uuidString).jsonl")
        let rotation = FileSink.Rotation(maxBytes: 256 * 1024, maxFiles: 2, compression: .zlib)
        let sink = FileSink(url: url, rotation: rotation, buffering: .init(maxBytes: 4 * 1024, flushInterval: 0))
        LogSystem.bootstrap(configuration: .default, sinks: [sink])

        let log = Log(category: "RotateCompress")
        let payload = String(repeating: "x", count: 2048)
        for i in 0..<300 {
            log.info("line \(i) \(payload)")
        }
        await LogSystem.flush()

        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let rotated = items.filter { $0.lastPathComponent.hasPrefix(url.deletingPathExtension().lastPathComponent + "-") }
        let hasCompressed = rotated.contains { $0.pathExtension == "zlib" }
        XCTAssertTrue(hasCompressed)
        try? FileManager.default.removeItem(at: url)
        for item in rotated {
            try? FileManager.default.removeItem(at: item)
        }
        #else
        throw XCTSkip("Compression not available")
        #endif
    }

    func testOverridesApplyEnvironment() async throws {
        let prefix = "MODERNSWIFTLOGGER_"
        let previous = EnvSnapshot(value: getenv("\(prefix)MIN_LEVEL").flatMap { String(cString: $0) })
        setenv("\(prefix)MIN_LEVEL", "error", 1)
        defer {
            if let value = previous.value {
                setenv("\(prefix)MIN_LEVEL", value, 1)
            } else {
                unsetenv("\(prefix)MIN_LEVEL")
            }
        }

        var config = LogConfiguration.recommended()
        config.applyOverrides([.environment(prefix: prefix)])
        let sink = TestSink()
        LogSystem.bootstrap(configuration: config, sinks: [sink])

        let log = Log(category: "Env")
        log.info("drop")
        log.error("keep")

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.message, "keep")
    }
}
#endif

#if canImport(XCTest)
import Foundation
import XCTest
@testable import ModernSwiftLogger

final class ModernSwiftLoggerTests: XCTestCase {
    private struct TestError: Error {}
    private struct EnvSnapshot {
        let value: String?
    }
    private final class LineCapture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lines: [String] = []

        func write(_ line: String, _ isError: Bool) throws {
            lock.lock()
            lines.append(line)
            lock.unlock()
            _ = isError
        }
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

    func testEnvMergePolicyOverrides() async throws {
        let prefix = "MODERNSWIFTLOGGER_"
        let previous = EnvSnapshot(value: getenv("\(prefix)MERGE_POLICY").flatMap { String(cString: $0) })
        setenv("\(prefix)MERGE_POLICY", "keepExisting", 1)
        defer {
            if let value = previous.value {
                setenv("\(prefix)MERGE_POLICY", value, 1)
            } else {
                unsetenv("\(prefix)MERGE_POLICY")
            }
        }

        var config = LogConfiguration.default
        config.applyOverrides([.environment(prefix: prefix)])
        let sink = TestSink()
        LogSystem.bootstrap(configuration: config, sinks: [sink])

        let log = Log(category: "Env").withMetadata(["k": .string("logger")])
        log.info("test", metadata: ["k": .string("call")])

        await LogSystem.flush()
        let events = await sink.snapshot()
        if case .string(let value)? = events.first?.metadata["k"] {
            XCTAssertEqual(value, "logger")
        } else {
            XCTFail("missing metadata")
        }
    }

    func testEnvTextStyleAliasPretty() {
        let prefix = "MODERNSWIFTLOGGER_"
        let previous = EnvSnapshot(value: getenv("\(prefix)TEXT_STYLE").flatMap { String(cString: $0) })
        setenv("\(prefix)TEXT_STYLE", "pretty", 1)
        defer {
            if let value = previous.value {
                setenv("\(prefix)TEXT_STYLE", value, 1)
            } else {
                unsetenv("\(prefix)TEXT_STYLE")
            }
        }

        var config = LogConfiguration.default
        config.applyOverrides([.environment(prefix: prefix)])
        XCTAssertEqual(config.textStyle, .verbose)
    }

    func testEnvIncludeExcludeTagsAndCategories() async throws {
        let prefix = "MODERNSWIFTLOGGER_"
        let prevIncludeCats = EnvSnapshot(value: getenv("\(prefix)INCLUDE_CATEGORIES").flatMap { String(cString: $0) })
        let prevIncludeTags = EnvSnapshot(value: getenv("\(prefix)INCLUDE_TAGS").flatMap { String(cString: $0) })
        let prevExcludeTags = EnvSnapshot(value: getenv("\(prefix)EXCLUDE_TAGS").flatMap { String(cString: $0) })
        setenv("\(prefix)INCLUDE_CATEGORIES", "Keep", 1)
        setenv("\(prefix)INCLUDE_TAGS", "feature:Allow", 1)
        setenv("\(prefix)EXCLUDE_TAGS", "bug:Block", 1)
        defer {
            if let value = prevIncludeCats.value { setenv("\(prefix)INCLUDE_CATEGORIES", value, 1) } else { unsetenv("\(prefix)INCLUDE_CATEGORIES") }
            if let value = prevIncludeTags.value { setenv("\(prefix)INCLUDE_TAGS", value, 1) } else { unsetenv("\(prefix)INCLUDE_TAGS") }
            if let value = prevExcludeTags.value { setenv("\(prefix)EXCLUDE_TAGS", value, 1) } else { unsetenv("\(prefix)EXCLUDE_TAGS") }
        }

        var config = LogConfiguration.default
        config.applyOverrides([.environment(prefix: prefix)])
        let sink = TestSink()
        LogSystem.bootstrap(configuration: config, sinks: [sink])

        let logKeep = Log(category: "Keep")
        logKeep.info("allow", tags: [.feature("Allow")])
        logKeep.info("blocked", tags: [.bug("Block")])
        let logDrop = Log(category: "Drop")
        logDrop.info("drop", tags: [.feature("Allow")])

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.message, "allow")
    }

    func testContextMergeSemantics() async throws {
        var config = LogConfiguration.default
        config.metadataMergePolicy = .keepExisting
        let sink = TestSink()
        LogSystem.bootstrap(configuration: config, sinks: [sink])

        let log = Log(category: "Ctx").withMetadata(["k": .string("logger")])
        await LogSystem.withContext(metadata: ["k": .string("task")]) {
            log.info("event", metadata: ["k": .string("call")])
        }

        await LogSystem.flush()
        let events = await sink.snapshot()
        if case .string(let value)? = events.first?.metadata["k"] {
            XCTAssertEqual(value, "logger")
        } else {
            XCTFail("missing metadata")
        }
    }

    func testContextMergeSemanticsReplace() async throws {
        var config = LogConfiguration.default
        config.metadataMergePolicy = .replaceWithNew
        let sink = TestSink()
        LogSystem.bootstrap(configuration: config, sinks: [sink])

        let log = Log(category: "Ctx").withMetadata(["k": .string("logger")])
        await LogSystem.withContext(metadata: ["k": .string("task")]) {
            log.info("event", metadata: ["k": .string("call")])
        }

        await LogSystem.flush()
        let events = await sink.snapshot()
        if case .string(let value)? = events.first?.metadata["k"] {
            XCTAssertEqual(value, "call")
        } else {
            XCTFail("missing metadata")
        }
    }

    func testEventStreamReceivesEvents() async throws {
        let sink = TestSink()
        LogSystem.bootstrap(configuration: .default, sinks: [sink])
        let stream = LogSystem.events(bufferingPolicy: .bufferingOldest(10))
        let task = Task<LogEvent?, Never> {
            for await event in stream {
                return event
            }
            return nil
        }
        Log(category: "Stream").info("stream")
        await LogSystem.flush()
        let event = await task.value
        XCTAssertEqual(event?.message, "stream")
    }

    func testMarkerAndSpanReservedMetadata() async throws {
        let sink = TestSink()
        LogSystem.bootstrap(configuration: .default, sinks: [sink])
        let log = Log(category: "Trace")
        log.marker("MARK")
        let span = log.span("Work")
        span.end()

        await LogSystem.flush()
        let events = await sink.snapshot()
        XCTAssertTrue(events.count >= 2)

        let marker = events.first { $0.message.contains("MARKER") }
        if case .object(let obj)? = marker?.metadata[LogReservedMetadata.key],
           case .string(let kind)? = obj[LogReservedMetadata.kind] {
            XCTAssertEqual(kind, LogReservedMetadata.kindMarker)
        } else {
            XCTFail("missing marker reserved metadata")
        }

        let spanEvents = events.filter { $0.message.contains("SPAN_") }
        let start = spanEvents.first { $0.message.contains("SPAN_START") }
        let end = spanEvents.first { $0.message.contains("SPAN_END") }
        if case .object(let startMeta)? = start?.metadata[LogReservedMetadata.key],
           case .string(let startID)? = startMeta[LogReservedMetadata.spanID],
           case .object(let endMeta)? = end?.metadata[LogReservedMetadata.key],
           case .string(let endID)? = endMeta[LogReservedMetadata.spanID] {
            XCTAssertEqual(startID, endID)
        } else {
            XCTFail("missing span reserved metadata")
        }
    }

    func testDeterministicJSONOutput() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("modernswiftlogger-\(UUID().uuidString).jsonl")
        let sink = FileSink(url: url, buffering: .init(maxBytes: 1, flushInterval: 0), deterministicJSON: true)
        LogSystem.bootstrap(configuration: .default, sinks: [sink])

        let log = Log(category: "Deterministic")
        log.info("event", metadata: ["z": .int(1), "a": .int(2)])
        await LogSystem.flush()

        let data = try Data(contentsOf: url)
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(LogEvent.self, from: Data(line.utf8))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let expected = String(decoding: try encoder.encode(event), as: UTF8.self)
        XCTAssertEqual(line, expected)
        try? FileManager.default.removeItem(at: url)
    }

    func testStdoutSinkWriterInjection() async throws {
        let capture = LineCapture()
        let config = LogConfiguration.default
        let sink = StdoutSink(format: .json, configuration: config, writer: capture.write)
        LogSystem.bootstrap(configuration: config, sinks: [sink])

        Log(category: "Stdout").info("hello")
        await LogSystem.flush()
        XCTAssertEqual(capture.lines.count, 1)
        XCTAssertTrue(capture.lines.first?.contains("\"message\":\"hello\"") == true)
    }

    func testRotationFileNamesAreUnique() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("modernswiftlogger-\(UUID().uuidString).jsonl")
        let rotation = FileSink.Rotation(maxBytes: 256 * 1024, maxFiles: 5, compression: .none)
        let sink = FileSink(url: url, rotation: rotation, buffering: .init(maxBytes: 4 * 1024, flushInterval: 0))
        LogSystem.bootstrap(configuration: .default, sinks: [sink])

        let log = Log(category: "Rotate")
        let payload = String(repeating: "x", count: 4096)
        for i in 0..<400 {
            log.info("line \(i) \(payload)")
        }
        await LogSystem.flush()

        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let rotated = items.filter { $0.lastPathComponent.hasPrefix(url.deletingPathExtension().lastPathComponent + "-") }
        let names = rotated.map { $0.lastPathComponent }
        XCTAssertEqual(Set(names).count, names.count)
        try? FileManager.default.removeItem(at: url)
        for item in rotated {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func testRotationAppliesFileOptions() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("modernswiftlogger-\(UUID().uuidString).jsonl")
        let rotation = FileSink.Rotation(maxBytes: 256 * 1024, maxFiles: 2, compression: .none)
        let options = FileSink.FileOptions(protection: nil, excludeFromBackup: true)
        let sink = FileSink(url: url, rotation: rotation, buffering: .init(maxBytes: 4 * 1024, flushInterval: 0), fileOptions: options)
        LogSystem.bootstrap(configuration: .default, sinks: [sink])

        let log = Log(category: "Rotate")
        let payload = String(repeating: "x", count: 4096)
        for i in 0..<300 {
            log.info("line \(i) \(payload)")
        }
        await LogSystem.flush()

        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isExcludedFromBackupKey])
        let rotated = items.filter { $0.lastPathComponent.hasPrefix(url.deletingPathExtension().lastPathComponent + "-") }
        if let file = rotated.first {
            let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        } else {
            XCTFail("missing rotated file")
        }
        try? FileManager.default.removeItem(at: url)
        for item in rotated {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
#endif

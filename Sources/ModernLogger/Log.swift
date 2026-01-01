import Foundation
import Dispatch
#if canImport(OSLog)
import OSLog
#endif

// MARK: - Public logger type

/// A lightweight logger bound to a subsystem+category, with optional persistent context.
///
/// Typical usage:
///   let log = Log(category: "Networking")
///   log.info("Started", metadata: ["url": .string(url.absoluteString)])
public struct Log: Sendable {
    public var subsystem: String
    public var category: String
    public var context: LogContext

    public init(subsystem: String = LogSystem.defaultSubsystem, category: String, context: LogContext = .empty) {
        self.subsystem = subsystem
        self.category = category
        self.context = context
    }

    /// Convenience: feature tag.
    public func taggedFeature(_ name: String) -> Log {
        tagged([.feature(name)])
    }

    /// Convenience: bug tag.
    public func taggedBug(_ id: String) -> Log {
        tagged([.bug(id)])
    }

    /// Convenience: marker tag.
    public func taggedMarker(_ key: String) -> Log {
        tagged([.marker(key)])
    }

    /// Add tags permanently to this logger (returns a new value).
    public func tagged(_ tags: LogTag...) -> Log {
        tagged(Set(tags))
    }

    public func tagged(_ tags: Set<LogTag>) -> Log {
        var copy = self
        copy.context.tags.formUnion(tags)
        return copy
    }

    /// Add metadata permanently to this logger (returns a new value).
    public func withMetadata(_ metadata: LogMetadata) -> Log {
        var copy = self
        copy.context.metadata.merge(metadata, uniquingKeysWith: { _, new in new })
        return copy
    }

    /// Feature-scoped logger (grep-friendly).
    public func forFeature(_ name: String) -> Log { tagged([.feature(name)]) }

    /// Bug-scoped logger (grep-friendly).
    public func forBug(_ id: String) -> Log { tagged([.bug(id)]) }

    /// Marker breadcrumb (grep-friendly).
    public func marker(
        _ key: String,
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .notice,
            "MARKER \(key)",
            tags: [.marker(key)],
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    // MARK: Level-specific convenience

    public func trace(
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .trace,
            message(),
            tags: tags,
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    public func debug(
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .debug,
            message(),
            tags: tags,
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    public func info(
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .info,
            message(),
            tags: tags,
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    public func notice(
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .notice,
            message(),
            tags: tags,
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    public func warning(
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .warning,
            message(),
            tags: tags,
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    public func error(
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .error,
            message(),
            tags: tags,
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    public func critical(
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            .critical,
            message(),
            tags: tags,
            metadata: metadata(),
            fileID: fileID,
            function: function,
            line: line
        )
    }

    // MARK: Core

    /// Core logging API (structured + multi-sink).
    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        tags: [LogTag] = [],
        metadata: @autoclosure () -> LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        let cfg = LogSystem.snapshot()

        // Merge contexts without evaluating the message unless we pass the filter.
        let taskContext = LogSystem.TaskLocalContext.context
        var mergedContext = self.context.merging(taskContext, policy: cfg.metadataMergePolicy)
        if !tags.isEmpty {
            mergedContext.tags.formUnion(tags)
        }

        guard cfg.allows(level: level, category: category, tags: mergedContext.tags) else {
            return
        }

        var mergedMetadata = mergedContext.metadata
        switch cfg.metadataMergePolicy {
        case .replaceWithNew:
            mergedMetadata.merge(metadata(), uniquingKeysWith: { _, new in new })
        case .keepExisting:
            mergedMetadata.merge(metadata(), uniquingKeysWith: { existing, _ in existing })
        }

        let rawMessage = message()
        let finalMessage: String
        if let maxBytes = cfg.maxMessageBytes {
            finalMessage = LogString.truncateUTF8(rawMessage, maxBytes: maxBytes)
        } else {
            finalMessage = rawMessage
        }

        // Caller location optionally included.
        let src: SourceLocation? = cfg.includeSourceLocation
            ? SourceLocation(fileID: fileID, function: function, line: line)
            : nil

        // Execution context optionally included.
        let exec: ExecutionContext? = cfg.includeExecutionContext
            ? ExecutionContext.capture()
            : nil

        // Stable ordering for tags in output.
        let tagStrings = mergedContext.tags.map(\.rawValue).sorted()

        let event = LogEvent(
            level: level,
            subsystem: subsystem,
            category: category,
            message: finalMessage,
            tags: tagStrings,
            metadata: mergedMetadata,
            source: src,
            execution: exec
        )

        LogSystem.emit(event)
    }
}

/// Correlation scope helper (tags + metadata bound to a logger).
/// Correlation scope helper (tags + metadata bound to a logger).
public struct LogScope: Sendable {
    public let id: String
    public let logger: Log

    public init(base: Log, id: String = UUID().uuidString, tagPrefix: String = "corr") {
        self.id = id
        let tag = LogTag("\(tagPrefix):\(id)")
        self.logger = base.tagged(tag).withMetadata(["correlation_id": .string(id)])
    }
}

/// Span helper for measuring elapsed time and emitting start/end events.
public struct LogSpan: Sendable {
    private let logger: Log
    private let name: String
    private let level: LogLevel
    private let start: DispatchTime
    private let tags: [LogTag]
    private let metadata: LogMetadata
    private let fileID: String
    private let function: String
    private let line: UInt
    private let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false

        func markEnded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if ended { return false }
            ended = true
            return true
        }
    }

    public init(
        logger: Log,
        name: String,
        level: LogLevel,
        tags: [LogTag],
        metadata: LogMetadata,
        fileID: String,
        function: String,
        line: UInt
    ) {
        self.logger = logger
        self.name = name
        self.level = level
        self.tags = tags
        self.metadata = metadata
        self.fileID = fileID
        self.function = function
        self.line = line
        self.start = DispatchTime.now()

        logger.log(level, "SPAN_START \(name)", tags: tags, metadata: metadata, fileID: fileID, function: function, line: line)
    }

    public func end(
        status: String? = nil,
        error: Error? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        guard state.markEnded() else { return }
        let durationNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let durationMs = Double(durationNs) / 1_000_000

        var meta = metadata
        meta["duration_ms"] = .double(durationMs)
        if let status {
            meta["status"] = .string(status)
        }
        if let error {
            meta["error"] = .error(error)
        }

        logger.log(level, "SPAN_END \(name)", tags: tags, metadata: meta, fileID: fileID, function: function, line: line)
    }
}

public extension Log {
    static var `default`: Log { Log(category: "Default") }

    func scoped(id: String = UUID().uuidString, tagPrefix: String = "corr") -> LogScope {
        LogScope(base: self, id: id, tagPrefix: tagPrefix)
    }

    @discardableResult
    func span(
        _ name: String,
        level: LogLevel = .info,
        tags: [LogTag] = [],
        metadata: LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) -> LogSpan {
        LogSpan(
            logger: self,
            name: name,
            level: level,
            tags: tags,
            metadata: metadata,
            fileID: fileID,
            function: function,
            line: line
        )
    }

    @discardableResult
    func measure<T>(
        _ name: String,
        level: LogLevel = .info,
        tags: [LogTag] = [],
        metadata: LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line,
        operation: () throws -> T
    ) rethrows -> T {
        let span = self.span(name, level: level, tags: tags, metadata: metadata, fileID: fileID, function: function, line: line)
        do {
            let result = try operation()
            span.end(status: "ok")
            return result
        } catch {
            span.end(status: "error", error: error)
            throw error
        }
    }

    @discardableResult
    func measure<T>(
        _ name: String,
        level: LogLevel = .info,
        tags: [LogTag] = [],
        metadata: LogMetadata = [:],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line,
        operation: () async throws -> T
    ) async rethrows -> T {
        let span = self.span(name, level: level, tags: tags, metadata: metadata, fileID: fileID, function: function, line: line)
        do {
            let result = try await operation()
            span.end(status: "ok")
            return result
        } catch {
            span.end(status: "error", error: error)
            throw error
        }
    }
}
// MARK: - Signposts (optional helper)
//
// If you want "Points of Interest" style intervals/events in Instruments,
// this wrapper uses OSSignposter when available.
//
// Usage:
//   let log = Log(category: "DB")
//   await log.signpostInterval("LoadUser") { ... }
//
// NOTE: This is separate from normal text logs; signposts are for performance tracing.
#if canImport(OSLog)
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
private final class SignpostCache: @unchecked Sendable {
    static let shared = SignpostCache()

    private struct Key: Hashable {
        let subsystem: String
        let category: String
    }

    private let lock = NSLock()
    private var cache: [Key: OSSignposter] = [:]

    func signposter(subsystem: String, category: String) -> OSSignposter {
        let key = Key(subsystem: subsystem, category: category)
        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        let logger = Logger(subsystem: subsystem, category: category)
        let signposter = OSSignposter(logger: logger)
        cache[key] = signposter
        lock.unlock()
        return signposter
    }
}

public extension Log {
    /// Measure a synchronous interval with Instruments signposts.
    @discardableResult
    func signpostInterval<T>(
        _ name: StaticString,
        metadata: String? = nil,
        operation: () throws -> T
    ) rethrows -> T {
        let signposter = SignpostCache.shared.signposter(subsystem: subsystem, category: category)
        let id = signposter.makeSignpostID()

        let state: OSSignpostIntervalState
        if let metadata {
            state = signposter.beginInterval(name, id: id, "\(metadata, privacy: .public)")
        } else {
            state = signposter.beginInterval(name, id: id)
        }

        defer { signposter.endInterval(name, state) }
        return try operation()
    }

    /// Measure an async interval with Instruments signposts.
    @discardableResult
    func signpostInterval<T>(
        _ name: StaticString,
        metadata: String? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        let signposter = SignpostCache.shared.signposter(subsystem: subsystem, category: category)
        let id = signposter.makeSignpostID()

        let state: OSSignpostIntervalState
        if let metadata {
            state = signposter.beginInterval(name, id: id, "\(metadata, privacy: .public)")
        } else {
            state = signposter.beginInterval(name, id: id)
        }

        do {
            let result = try await operation()
            signposter.endInterval(name, state)
            return result
        } catch {
            signposter.endInterval(name, state, "\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Emit a single signpost event (point-in-time).
    func signpostEvent(_ name: StaticString, metadata: String? = nil) {
        let signposter = SignpostCache.shared.signposter(subsystem: subsystem, category: category)
        let id = signposter.makeSignpostID()
        if let metadata {
            signposter.emitEvent(name, id: id, "\(metadata, privacy: .public)")
        } else {
            signposter.emitEvent(name, id: id)
        }
    }
}
#endif

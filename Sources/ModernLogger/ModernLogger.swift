import Foundation
import Dispatch
#if canImport(OSLog)
import OSLog
#endif

// MARK: - Overview (for humans + AI agents)
/*
ModernLogger
============

A modern, multi-sink, structured logger for all Apple platforms, built around:
- Unified Logging (OSLog / Logger) for native system integration
- Optional JSON Lines (JSONL) file sink for AI-friendly "scanable" logs
- Optional stdout sink for CI/tests/agents
- Feature/Bug tagging + high-signal "markers" for targeted debugging
- Task-local context (tags/metadata) to avoid plumbing IDs through every call

Quick Start
-----------
1) Bootstrap once at app startup:

    import ModernLogger

    LogSystem.bootstrapFromEnvironment() // default is OSLog; env can add stdout/file

2) Create loggers per area:

    let log = Log(category: "Networking")

3) Log:

    log.info("Request started", metadata: ["url": .string(url.absoluteString)])

Feature/Bug debugging
---------------------
- Attach tags that are easy to grep and easy for AI agents to filter:

    log.forFeature("Checkout").debug("step=validate")
    log.forBug("JIRA-1234").warning("Unexpected server response")

- Drop an explicit marker breadcrumb:

    log.marker("CHECKOUT_FLOW_ENTER")

Task-local context (great for request IDs)
-----------------------------------------
    let requestID = UUID().uuidString
    await LogSystem.withContext(
        tags: [.feature("Search")],
        metadata: ["request_id": .string(requestID)]
    ) {
        log.info("Search started")
        // ... all logs in this task inherit those tags/metadata
    }

Environment toggles (agent-friendly)
------------------------------------
- MODERNLOGGER_MIN_LEVEL=debug
- MODERNLOGGER_INCLUDE_TAGS=feature:Checkout,bug:JIRA-1234
- MODERNLOGGER_STDOUT=1
- MODERNLOGGER_STDOUT_FORMAT=json   (or "text")
- MODERNLOGGER_FILE=1               (writes JSONL to caches dir)
- MODERNLOGGER_FILE_NAME=modernlogger.jsonl
- MODERNLOGGER_FILE_MAX_MB=10
- MODERNLOGGER_REDACT_KEYS=password,token,authorization

*/

// MARK: - Public Types

/// Log severity used by ModernLogger (more granular than OSLogType).
public enum LogLevel: Int, Sendable, CaseIterable, Comparable, Codable {
    case trace = 0
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var name: String {
        switch self {
        case .trace: "trace"
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .warning: "warning"
        case .error: "error"
        case .critical: "critical"
        }
    }

    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch s {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "notice": self = .notice
        case "warn", "warning": self = .warning
        case "err", "error": self = .error
        case "crit", "critical", "fatal", "fault": self = .critical
        default: return nil
        }
    }

    // Encode as a readable string instead of an int.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self.name)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), let v = LogLevel(s) {
            self = v
            return
        }
        let raw = (try? c.decode(Int.self)) ?? LogLevel.info.rawValue
        self = LogLevel(rawValue: raw) ?? .info
    }
}

/// Explicit privacy "mode" for OSLog sink.
/// Note: This controls privacy applied to the rendered message string.
/// You should still avoid logging secrets; redaction is best-effort.
public enum LogPrivacy: String, Sendable, Codable {
    case `public`
    case `private`
    case sensitive
}

/// A searchable "tag" string (feature/bug/marker/anything).
public struct LogTag: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    // High-signal conventions (recommended):
    public static func feature(_ name: String) -> LogTag { .init("feature:\(normalize(name))") }
    public static func bug(_ id: String) -> LogTag { .init("bug:\(normalize(id))") }
    public static func marker(_ key: String) -> LogTag { .init("marker:\(normalize(key))") }

    // Optional: AI hints (if you want a dedicated namespace)
    public static func ai(_ label: String) -> LogTag { .init("ai:\(normalize(label))") }

    private static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep it grep-friendly; replace whitespace with underscores.
        return trimmed.replacingOccurrences(of: #"[\s]+"#, with: "_", options: .regularExpression)
    }
}

/// JSON-friendly metadata value (keeps the file sink structured).
public enum LogValue: Sendable, Codable, CustomStringConvertible,
                      ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                      ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {

    case null
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case uuid(UUID)
    case array([LogValue])
    case object([String: LogValue])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public var description: String {
        switch self {
        case .null: return "null"
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return String(v)
        case .date(let v): return v.formatted(.iso8601)
        case .uuid(let v): return v.uuidString
        case .array(let v): return "[" + v.map(\.description).joined(separator: ", ") + "]"
        case .object(let v):
            let keys = v.keys.sorted()
            let pairs = keys.map { "\($0)=\(v[$0]!.description)" }.joined(separator: ", ")
            return "{\(pairs)}"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .date(let v): try c.encode(v)
        case .uuid(let v): try c.encode(v.uuidString)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }

        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }

        // Decode Date if decoder is configured for it (we use iso8601 for sinks).
        if let v = try? c.decode(Date.self) { self = .date(v); return }

        if let v = try? c.decode(String.self) {
            // Try UUID parsing; if it fails, keep as string.
            if let uuid = UUID(uuidString: v) { self = .uuid(uuid); return }
            self = .string(v); return
        }

        if let v = try? c.decode([LogValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: LogValue].self) { self = .object(v); return }

        self = .null
    }
}

public typealias LogMetadata = [String: LogValue]

/// Caller source location.
public struct SourceLocation: Sendable, Codable {
    public var fileID: String
    public var function: String
    public var line: UInt

    public init(fileID: String, function: String, line: UInt) {
        self.fileID = fileID
        self.function = function
        self.line = line
    }
}

/// Optional execution context (useful when stdout/file logs are analyzed outside Xcode).
public struct ExecutionContext: Sendable, Codable {
    public var isMainThread: Bool
    public var threadName: String?
    public var queueLabel: String?
    public var taskPriority: String?

    public init(isMainThread: Bool, threadName: String?, queueLabel: String?, taskPriority: String?) {
        self.isMainThread = isMainThread
        self.threadName = threadName
        self.queueLabel = queueLabel
        self.taskPriority = taskPriority
    }

    public static func capture() -> ExecutionContext {
        let isMain = Thread.isMainThread
        let tname = Thread.current.name

        let labelCString = __dispatch_queue_get_label(nil)
        let label = String(cString: labelCString)

        // Task priority is meaningful when called from async contexts; otherwise it's still safe.
        let priority = String(describing: Task.currentPriority)

        return ExecutionContext(
            isMainThread: isMain,
            threadName: tname,
            queueLabel: label.isEmpty ? nil : label,
            taskPriority: priority
        )
    }
}

/// Log event schema (JSONL encoding uses this).
public struct LogEvent: Sendable, Codable {
    public static let schemaVersion: Int = 1

    public var schemaVersion: Int
    public var id: UUID
    public var timestamp: Date
    public var level: LogLevel
    public var subsystem: String
    public var category: String
    public var message: String
    public var tags: [String]
    public var metadata: LogMetadata
    public var source: SourceLocation?
    public var execution: ExecutionContext?

    public init(
        schemaVersion: Int = LogEvent.schemaVersion,
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        subsystem: String,
        category: String,
        message: String,
        tags: [String],
        metadata: LogMetadata,
        source: SourceLocation?,
        execution: ExecutionContext?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.tags = tags
        self.metadata = metadata
        self.source = source
        self.execution = execution
    }
}

/// Per-task and per-logger context (tags + metadata).
public struct LogContext: Sendable, Codable {
    public var tags: Set<LogTag>
    public var metadata: LogMetadata

    public init(tags: Set<LogTag> = [], metadata: LogMetadata = [:]) {
        self.tags = tags
        self.metadata = metadata
    }

    public static let empty = LogContext()

    public func merging(_ other: LogContext) -> LogContext {
        var out = self
        out.tags.formUnion(other.tags)
        out.metadata.merge(other.metadata, uniquingKeysWith: { _, new in new })
        return out
    }
}

/// Filtering rules for the logging pipeline.
/// `includeTags` acts like a focused debug allowlist: if not empty,
/// an event must contain at least one of the includeTags to pass.
public struct LogFilter: Sendable, Codable {
    public var minimumLevel: LogLevel
    public var includeCategories: Set<String>
    public var excludeCategories: Set<String>
    public var includeTags: Set<String>
    public var excludeTags: Set<String>

    public init(
        minimumLevel: LogLevel,
        includeCategories: Set<String> = [],
        excludeCategories: Set<String> = [],
        includeTags: Set<String> = [],
        excludeTags: Set<String> = []
    ) {
        self.minimumLevel = minimumLevel
        self.includeCategories = includeCategories
        self.excludeCategories = excludeCategories
        self.includeTags = includeTags
        self.excludeTags = excludeTags
    }

    public func allows(level: LogLevel, category: String, tags: Set<LogTag>) -> Bool {
        guard level >= minimumLevel else { return false }

        if !includeCategories.isEmpty, !includeCategories.contains(category) {
            return false
        }
        if excludeCategories.contains(category) {
            return false
        }

        let tagStrings = Set(tags.map(\.rawValue))

        if !includeTags.isEmpty, includeTags.isDisjoint(with: tagStrings) {
            return false
        }
        if !excludeTags.isEmpty, !excludeTags.isDisjoint(with: tagStrings) {
            return false
        }

        return true
    }
}

public enum StdoutFormat: String, Sendable, Codable {
    case text
    case json
}

public enum LogTextStyle: String, Sendable, Codable {
    /// `ts level subsystem/category message tags meta src`
    case compact
    /// More verbose text format (includes execution context if present).
    case verbose
}

/// Global configuration (filtering + formatting + redaction).
public struct LogConfiguration: Sendable, Codable {
    public var filter: LogFilter

    public var oslogPrivacy: LogPrivacy
    public var includeSourceLocation: Bool
    public var includeExecutionContext: Bool

    public var textStyle: LogTextStyle

    /// Metadata keys to remove or replace before any sink sees them.
    public var redactedMetadataKeys: Set<String>

    /// AsyncStream buffer capacity (older events dropped when full).
    public var streamBufferCapacity: Int

    public init(
        filter: LogFilter,
        oslogPrivacy: LogPrivacy,
        includeSourceLocation: Bool,
        includeExecutionContext: Bool,
        textStyle: LogTextStyle,
        redactedMetadataKeys: Set<String>,
        streamBufferCapacity: Int
    ) {
        self.filter = filter
        self.oslogPrivacy = oslogPrivacy
        self.includeSourceLocation = includeSourceLocation
        self.includeExecutionContext = includeExecutionContext
        self.textStyle = textStyle
        self.redactedMetadataKeys = redactedMetadataKeys
        self.streamBufferCapacity = max(16, streamBufferCapacity)
    }

    public static var `default`: LogConfiguration {
        #if DEBUG
        let minLevel: LogLevel = .debug
        let privacy: LogPrivacy = .public
        let includeSource = true
        #else
        let minLevel: LogLevel = .info
        let privacy: LogPrivacy = .private
        let includeSource = false
        #endif

        return LogConfiguration(
            filter: LogFilter(minimumLevel: minLevel),
            oslogPrivacy: privacy,
            includeSourceLocation: includeSource,
            includeExecutionContext: false,
            textStyle: .compact,
            redactedMetadataKeys: [],
            streamBufferCapacity: 1024
        )
    }

    /// Apply environment overrides (great for tests/CI/AI agents).
    public mutating func applyEnvironment(prefix: String = "MODERNLOGGER_") {
        let env = ProcessInfo.processInfo.environment

        if let s = env["\(prefix)MIN_LEVEL"] ?? env["\(prefix)LEVEL"],
           let lvl = LogLevel(s) {
            filter.minimumLevel = lvl
        }

        if let s = env["\(prefix)INCLUDE_CATEGORIES"] {
            filter.includeCategories = Set(parseCSV(s))
        }
        if let s = env["\(prefix)EXCLUDE_CATEGORIES"] {
            filter.excludeCategories = Set(parseCSV(s))
        }

        if let s = env["\(prefix)INCLUDE_TAGS"] {
            filter.includeTags = Set(parseCSV(s))
        }
        if let s = env["\(prefix)EXCLUDE_TAGS"] {
            filter.excludeTags = Set(parseCSV(s))
        }

        if let s = env["\(prefix)OSLOG_PRIVACY"]?.lowercased(),
           let p = LogPrivacy(rawValue: s) {
            oslogPrivacy = p
        }

        if let s = env["\(prefix)SOURCE"], let b = parseBool(s) {
            includeSourceLocation = b
        }

        if let s = env["\(prefix)CONTEXT"], let b = parseBool(s) {
            includeExecutionContext = b
        }

        if let s = env["\(prefix)TEXT_STYLE"]?.lowercased(),
           let st = LogTextStyle(rawValue: s) {
            textStyle = st
        }

        if let s = env["\(prefix)REDACT_KEYS"] {
            redactedMetadataKeys = Set(parseCSV(s).map { $0.lowercased() })
        }

        if let s = env["\(prefix)BUFFER"], let n = Int(s), n > 0 {
            streamBufferCapacity = max(16, n)
        }
    }

    private func parseCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseBool(_ s: String) -> Bool? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch v {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: return nil
        }
    }
}

// MARK: - LogSink protocol + built-in sinks

public protocol LogSink: Sendable {
    func emit(_ event: LogEvent) async
    func flush() async
}

public extension LogSink {
    func flush() async { /* optional */ }
}

#if canImport(OSLog)
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
private extension LogPrivacy {
    var osLogPrivacy: OSLogPrivacy {
        switch self {
        case .public: .public
        case .private: .private
        case .sensitive: .sensitive
        }
    }
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
private extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug:
            return .debug
        case .info:
            return .info
        case .notice, .warning:
            return .default
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }
}

/// Native OSLog sink (Unified Logging).
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *)
public actor OSLogSink: LogSink {
    private struct Key: Hashable {
        var subsystem: String
        var category: String
    }

    private let privacy: LogPrivacy
    private var cache: [Key: Logger] = [:]

    public init(privacy: LogPrivacy = {
        #if DEBUG
        return .public
        #else
        return .private
        #endif
    }()) {
        self.privacy = privacy
    }

    public func emit(_ event: LogEvent) async {
        let key = Key(subsystem: event.subsystem, category: event.category)
        let logger: Logger
        if let existing = cache[key] {
            logger = existing
        } else {
            let created = Logger(subsystem: event.subsystem, category: event.category)
            cache[key] = created
            logger = created
        }

        // OSLog already captures timestamp/level/category; keep message compact.
        let body = LogFormatting.bodyText(for: event)
        switch privacy {
        case .public:
            logger.log(level: event.level.osLogType, "\(body, privacy: .public)")
        case .private:
            logger.log(level: event.level.osLogType, "\(body, privacy: .private)")
        case .sensitive:
            logger.log(level: event.level.osLogType, "\(body, privacy: .sensitive)")
        }
    }

    public func flush() async { /* OSLog is buffered by the system */ }
}
#endif

/// Stdout sink (good for tests/CI/agents).
public actor StdoutSink: LogSink {
    private let format: StdoutFormat
    private let configuration: LogConfiguration

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        return enc
    }()

    public init(format: StdoutFormat = .text, configuration: LogConfiguration) {
        self.format = format
        self.configuration = configuration
    }

    public func emit(_ event: LogEvent) async {
        let line: String
        switch format {
        case .text:
            line = LogFormatting.lineText(for: event, configuration: configuration)
        case .json:
            do {
                let data = try encoder.encode(event)
                line = String(decoding: data, as: UTF8.self)
            } catch {
                line = #"{"schemaVersion":1,"level":"error","message":"StdoutSink JSON encode failed","error":"\#(String(describing: error))"}"#
            }
        }

        // Write to stdout/stderr (errors -> stderr).
        let target = (event.level >= .error) ? FileHandle.standardError : FileHandle.standardOutput
        if let data = (line + "\n").data(using: .utf8) {
            do { try target.write(contentsOf: data) } catch { /* ignore */ }
        }
    }
}

/// JSONL file sink (one JSON object per line).
/// This is intentionally "agent-friendly" (easy to parse, grep, and attach to bug reports).
public actor FileSink: LogSink {
    public struct Rotation: Sendable, Codable {
        public var maxBytes: Int
        public var maxFiles: Int

        public init(maxBytes: Int = 10 * 1024 * 1024, maxFiles: Int = 5) {
            self.maxBytes = max(256 * 1024, maxBytes)
            self.maxFiles = max(1, maxFiles)
        }
    }

    public let url: URL
    private let rotation: Rotation

    private var fileHandle: FileHandle?
    private var currentSizeBytes: UInt64 = 0

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        return enc
    }()

    public init(url: URL, rotation: Rotation = Rotation()) {
        self.url = url
        self.rotation = rotation
    }

    public static func defaultURL(fileName: String = "modernlogger.jsonl") -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(fileName, isDirectory: false)
    }

    public func emit(_ event: LogEvent) async {
        do {
            try ensureOpen()
            let data = try encoder.encode(event)
            try rotateIfNeeded(adding: data.count + 1)
            try fileHandle?.write(contentsOf: data)
            try fileHandle?.write(contentsOf: Data([0x0A])) // newline
            currentSizeBytes += UInt64(data.count + 1)
        } catch {
            // If file logging fails, we intentionally do not crash the app.
            // You can still see OSLog/Stdout sinks if configured.
        }
    }

    public func flush() async {
        do { try fileHandle?.synchronize() } catch { /* ignore */ }
    }

    public func clear() async {
        do {
            try fileHandle?.close()
        } catch { /* ignore */ }
        fileHandle = nil
        currentSizeBytes = 0
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internals

    private func ensureOpen() throws {
        if fileHandle != nil { return }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        currentSizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        _ = try handle.seekToEnd()
        fileHandle = handle
    }

    private func rotateIfNeeded(adding bytes: Int) throws {
        guard rotation.maxBytes > 0 else { return }
        let projected = currentSizeBytes + UInt64(bytes)
        guard projected > UInt64(rotation.maxBytes) else { return }

        // Close current file first.
        try fileHandle?.close()
        fileHandle = nil

        // Move current file to a timestamped name.
        let ts = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "jsonl" : url.pathExtension
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(ts).\(ext)")

        // If move fails (e.g. file missing), just continue and recreate.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: url, to: rotated)
        }

        // Purge old rotations.
        purgeOldRotations(baseName: baseName, ext: ext)

        // Re-open a fresh file.
        try ensureOpen()
        currentSizeBytes = 0
    }

    private func purgeOldRotations(baseName: String, ext: String) {
        let dir = url.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }

        let rotated = items.filter {
            $0.lastPathComponent.hasPrefix(baseName + "-") && $0.pathExtension == ext
        }

        let sorted = rotated.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da > db
        }

        if sorted.count <= rotation.maxFiles { return }
        for url in sorted.dropFirst(rotation.maxFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// In-memory ring buffer sink (useful for tests and attach recent logs flows).
public actor InMemorySink: LogSink {
    private let capacity: Int
    private var buffer: [LogEvent] = []

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
        self.buffer.reserveCapacity(self.capacity)
    }

    public func emit(_ event: LogEvent) async {
        buffer.append(event)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    public func snapshot() async -> [LogEvent] {
        buffer
    }

    public func clear() async {
        buffer.removeAll(keepingCapacity: true)
    }
}

// MARK: - Formatting (shared)

enum LogFormatting {
    static func bodyText(for event: LogEvent) -> String {
        // Intended for OSLog message body (timestamp/level handled by OSLog UI).
        var parts: [String] = []
        parts.append(event.message)

        if !event.tags.isEmpty {
            parts.append("tags=[\(event.tags.joined(separator: " "))]")
        }

        if !event.metadata.isEmpty {
            let keys = event.metadata.keys.sorted()
            let pairs = keys.map { "\($0)=\(event.metadata[$0]!.description)" }
            parts.append("meta={\(pairs.joined(separator: " "))}")
        }

        if let src = event.source {
            parts.append("src=\(src.fileID):\(src.line)")
        }

        return parts.joined(separator: " | ")
    }

    static func lineText(for event: LogEvent, configuration: LogConfiguration) -> String {
        // Intended for stdout.
        let ts = event.timestamp.formatted(.iso8601)
        let lvl = event.level.name.uppercased()
        let scope = "\(event.subsystem)/\(event.category)"

        let body = bodyText(for: event)

        switch configuration.textStyle {
        case .compact:
            return "\(ts) [\(lvl)] [\(scope)] \(body)"

        case .verbose:
            var extra: [String] = []
            if let exec = event.execution {
                let thread = exec.isMainThread ? "main" : "bg"
                extra.append("thread=\(thread)")
                if let tn = exec.threadName { extra.append("tname=\(tn)") }
                if let q = exec.queueLabel { extra.append("queue=\(q)") }
                if let p = exec.taskPriority { extra.append("priority=\(p)") }
            }
            if extra.isEmpty {
                return "\(ts) [\(lvl)] [\(scope)] \(body)"
            } else {
                return "\(ts) [\(lvl)] [\(scope)] \(body) | \(extra.joined(separator: " "))"
            }
        }
    }
}

// MARK: - LogSystem (global pipeline + config)

public enum LogSystem {
    // Task-local context.
    public enum TaskLocalContext {
        @TaskLocal public static var context: LogContext = .empty
    }

    /// Run an async operation with additional task-local tags/metadata.
    public static func withContext<T>(
        tags: Set<LogTag> = [],
        metadata: LogMetadata = [:],
        operation: () async throws -> T
    ) async rethrows -> T {
        let extra = LogContext(tags: tags, metadata: metadata)
        return try await TaskLocalContext.$context.withValue(TaskLocalContext.context.merging(extra)) {
            try await operation()
        }
    }

    /// Global default subsystem.
    public static var defaultSubsystem: String { runtime.defaultSubsystem }

    /// Current dropped event count (buffer overflow, shutdown, etc).
    public static var droppedEventCount: UInt64 { runtime.droppedEventCount }

    /// Bootstraps the logging system with explicit config and sinks.
    /// Calling bootstrap multiple times replaces config + sinks (idempotent).
    public static func bootstrap(configuration: LogConfiguration, sinks: [any LogSink]) {
        runtime.bootstrap(configuration: configuration, sinks: sinks)
    }

    /// Convenient bootstrap that:
    /// - starts from `.default`
    /// - applies environment overrides
    /// - auto-adds sinks based on env flags (OSLog + optional stdout/file)
    public static func bootstrapFromEnvironment(prefix: String = "MODERNLOGGER_") {
        var config = LogConfiguration.default
        config.applyEnvironment(prefix: prefix)

        let env = ProcessInfo.processInfo.environment

        // Always include OSLog where available; else fall back to stdout text.
        var sinks: [any LogSink] = []

        #if canImport(OSLog)
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *) {
            sinks.append(OSLogSink(privacy: config.oslogPrivacy))
        }
        #endif

        // Add stdout if requested or if running in typical test/CI scenarios.
        let stdoutEnabled = parseBool(env["\(prefix)STDOUT"] ?? "") ?? false
        let isTests = env["XCTestConfigurationFilePath"] != nil
        if stdoutEnabled || isTests {
            let fmt = StdoutFormat(rawValue: (env["\(prefix)STDOUT_FORMAT"] ?? "text").lowercased()) ?? .text
            sinks.append(StdoutSink(format: fmt, configuration: config))
        }

        // Add file sink if requested.
        let fileEnabled = parseBool(env["\(prefix)FILE"] ?? "") ?? false
        if fileEnabled {
            let name = env["\(prefix)FILE_NAME"] ?? "modernlogger.jsonl"
            let maxMB = Int(env["\(prefix)FILE_MAX_MB"] ?? "") ?? 10
            let maxBytes = max(1, maxMB) * 1024 * 1024
            let url = FileSink.defaultURL(fileName: name)
            sinks.append(FileSink(url: url, rotation: .init(maxBytes: maxBytes, maxFiles: 5)))
        }

        // If nothing was added (e.g. OSLog unavailable), ensure at least stdout text.
        if sinks.isEmpty {
            sinks.append(StdoutSink(format: .text, configuration: config))
        }

        bootstrap(configuration: config, sinks: sinks)
    }

    /// Add a sink at runtime.
    public static func addSink(_ sink: any LogSink) {
        runtime.addSink(sink)
    }

    /// Replace configuration at runtime.
    public static func setConfiguration(_ configuration: LogConfiguration) {
        runtime.setConfiguration(configuration)
    }

    /// Flush all sinks (best-effort).
    public static func flush() async {
        await runtime.flush()
    }

    /// Finish the stream and flush sinks (useful in command-line tools/tests).
    public static func shutdown() async {
        await runtime.shutdown()
    }

    // MARK: - Internal use by Log

    static func snapshot() -> LogConfiguration {
        runtime.snapshot()
    }

    static func shouldLog(level: LogLevel, category: String, tags: Set<LogTag>) -> Bool {
        runtime.shouldLog(level: level, category: category, tags: tags)
    }

    static func emit(_ event: LogEvent) {
        runtime.emit(event)
    }

    private static func parseBool(_ s: String) -> Bool? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch v {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: return nil
        }
    }

    // MARK: - Runtime (private)

    private static let runtime = Runtime()

    private final class Runtime: @unchecked Sendable {
        private let lock = NSLock()

        private var configuration: LogConfiguration = .default
        private var manager: LogManager?
        private var continuation: AsyncStream<LogEvent>.Continuation?
        private var task: Task<Void, Never>?

        private var _dropped: UInt64 = 0

        var defaultSubsystem: String {
            // Environment override is handy for multi-app repos.
            let env = ProcessInfo.processInfo.environment
            if let s = env["MODERNLOGGER_SUBSYSTEM"], !s.isEmpty { return s }
            return Bundle.main.bundleIdentifier ?? "ModernLogger"
        }

        var droppedEventCount: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return _dropped
        }

        func bootstrap(configuration: LogConfiguration, sinks: [any LogSink]) {
            lock.lock()
            self.configuration = configuration

            if manager == nil {
                let mgr = LogManager(configuration: configuration, sinks: sinks)
                self.manager = mgr

                let policy: AsyncStream<LogEvent>.Continuation.BufferingPolicy = .bufferingOldest(configuration.streamBufferCapacity)
                let stream = AsyncStream<LogEvent>(bufferingPolicy: policy) { cont in
                    self.continuation = cont
                }

                self.task = Task.detached(priority: .utility) { [mgr] in
                    for await event in stream {
                        await mgr.process(event)
                    }
                    await mgr.flush()
                }
            } else if let mgr = manager {
                // Replace sinks + configuration.
                Task.detached(priority: .utility) {
                    await mgr.reconfigure(configuration: configuration, sinks: sinks)
                }
            }

            lock.unlock()
        }

        func addSink(_ sink: any LogSink) {
            // Ensure pipeline exists.
            ensureBootstrappedIfNeeded()
            if let mgr = manager {
                Task.detached(priority: .utility) { await mgr.addSink(sink) }
            }
        }

        func setConfiguration(_ configuration: LogConfiguration) {
            lock.lock()
            self.configuration = configuration
            let mgr = self.manager
            lock.unlock()

            ensureBootstrappedIfNeeded()
            if let mgr {
                Task.detached(priority: .utility) { await mgr.setConfiguration(configuration) }
            }
        }

        func snapshot() -> LogConfiguration {
            lock.lock()
            defer { lock.unlock() }
            return configuration
        }

        func shouldLog(level: LogLevel, category: String, tags: Set<LogTag>) -> Bool {
            lock.lock()
            let cfg = configuration
            lock.unlock()
            return cfg.filter.allows(level: level, category: category, tags: tags)
        }

        func emit(_ event: LogEvent) {
            ensureBootstrappedIfNeeded()

            lock.lock()
            let cont = continuation
            lock.unlock()

            guard let cont else {
                incrementDropped()
                return
            }

            let result = cont.yield(event)
            if case .enqueued = result {
                // ok
            } else {
                incrementDropped()
            }
        }

        func flush() async {
            ensureBootstrappedIfNeeded()
            guard let mgr = manager else { return }
            await mgr.flush()
        }

        func shutdown() async {
            let state = takeShutdownState()
            let cont = state.continuation
            let t = state.task
            let mgr = state.manager

            cont?.finish()
            _ = await t?.value
            await mgr?.flush()
        }

        private func ensureBootstrappedIfNeeded() {
            lock.lock()
            let hasPipeline = (manager != nil && continuation != nil && task != nil)
            let cfg = configuration
            lock.unlock()

            if hasPipeline { return }

            // Default: OSLog + (stdout in tests).
            var sinks: [any LogSink] = []

            #if canImport(OSLog)
            if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *) {
                sinks.append(OSLogSink(privacy: cfg.oslogPrivacy))
            }
            #endif

            let env = ProcessInfo.processInfo.environment
            let isTests = env["XCTestConfigurationFilePath"] != nil
            if isTests {
                sinks.append(StdoutSink(format: .text, configuration: cfg))
            }

            if sinks.isEmpty {
                sinks.append(StdoutSink(format: .text, configuration: cfg))
            }

            bootstrap(configuration: cfg, sinks: sinks)
        }

        private func incrementDropped() {
            lock.lock()
            _dropped &+= 1
            lock.unlock()
        }

        private struct ShutdownState {
            let continuation: AsyncStream<LogEvent>.Continuation?
            let task: Task<Void, Never>?
            let manager: LogManager?
        }

        private func takeShutdownState() -> ShutdownState {
            lock.lock()
            let cont = continuation
            continuation = nil
            let t = task
            task = nil
            let mgr = manager
            manager = nil
            lock.unlock()
            return ShutdownState(continuation: cont, task: t, manager: mgr)
        }
    }

    private actor LogManager {
        private var configuration: LogConfiguration
        private var sinks: [any LogSink]

        init(configuration: LogConfiguration, sinks: [any LogSink]) {
            self.configuration = configuration
            self.sinks = sinks
        }

        func reconfigure(configuration: LogConfiguration, sinks: [any LogSink]) {
            self.configuration = configuration
            self.sinks = sinks
        }

        func setConfiguration(_ configuration: LogConfiguration) {
            self.configuration = configuration
        }

        func addSink(_ sink: any LogSink) {
            sinks.append(sink)
        }

        func process(_ event: LogEvent) async {
            // Filter again here in case config changed between call-site and processing.
            // (Also important if some code emits directly to the pipeline.)
            let tags = Set(event.tags.map { LogTag($0) })
            guard configuration.filter.allows(level: event.level, category: event.category, tags: tags) else {
                return
            }

            let redacted = redact(event, keys: configuration.redactedMetadataKeys)

            for sink in sinks {
                await sink.emit(redacted)
            }
        }

        func flush() async {
            for sink in sinks {
                await sink.flush()
            }
        }

        private func redact(_ event: LogEvent, keys: Set<String>) -> LogEvent {
            guard !keys.isEmpty, !event.metadata.isEmpty else { return event }
            var e = event
            for (k, _) in event.metadata {
                if keys.contains(k.lowercased()) {
                    e.metadata[k] = .string("<redacted>")
                }
            }
            return e
        }
    }
}

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
        // Merge contexts without evaluating the message unless we pass the filter.
        let taskContext = LogSystem.TaskLocalContext.context
        var mergedContext = self.context.merging(taskContext)
        if !tags.isEmpty {
            mergedContext.tags.formUnion(tags)
        }

        guard LogSystem.shouldLog(level: level, category: category, tags: mergedContext.tags) else {
            return
        }

        let cfg = LogSystem.snapshot()

        var mergedMetadata = mergedContext.metadata
        mergedMetadata.merge(metadata(), uniquingKeysWith: { _, new in new })

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
            message: message(),
            tags: tagStrings,
            metadata: mergedMetadata,
            source: src,
            execution: exec
        )

        LogSystem.emit(event)
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
public extension Log {
    /// Measure a synchronous interval with Instruments signposts.
    @discardableResult
    func signpostInterval<T>(
        _ name: StaticString,
        metadata: String? = nil,
        operation: () throws -> T
    ) rethrows -> T {
        let logger = Logger(subsystem: subsystem, category: category)
        let signposter = OSSignposter(logger: logger)
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
        let logger = Logger(subsystem: subsystem, category: category)
        let signposter = OSSignposter(logger: logger)
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
        let logger = Logger(subsystem: subsystem, category: category)
        let signposter = OSSignposter(logger: logger)
        let id = signposter.makeSignpostID()
        if let metadata {
            signposter.emitEvent(name, id: id, "\(metadata, privacy: .public)")
        } else {
            signposter.emitEvent(name, id: id)
        }
    }
}
#endif

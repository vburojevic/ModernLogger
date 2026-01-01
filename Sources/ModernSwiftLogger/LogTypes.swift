import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Public Types

/// Log severity used by ModernSwiftLogger (more granular than OSLogType).
/// Severity level for log events.
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
/// Privacy mode used by the OSLog sink.
public enum LogPrivacy: String, Sendable, Codable {
    case `public`
    case `private`
    case sensitive
}

/// A searchable "tag" string (feature/bug/marker/anything).
/// Grep-friendly tag used for feature/bug/marker scoping.
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
/// JSON-friendly metadata value type.
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

    public enum DataEncoding: String, Sendable, Codable {
        case base64
        case utf8
        case hex
    }

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

    public static func url(_ value: URL) -> LogValue {
        .string(value.absoluteString)
    }

    public static func data(_ value: Data, encoding: DataEncoding = .base64, maxBytes: Int? = nil) -> LogValue {
        let data = maxBytes.map { Data(value.prefix(max(0, $0))) } ?? value
        switch encoding {
        case .base64:
            return .string(data.base64EncodedString())
        case .utf8:
            return .string(String(decoding: data, as: UTF8.self))
        case .hex:
            return .string(data.map { String(format: "%02x", $0) }.joined())
        }
    }

    public static func stringTruncated(_ value: String, maxBytes: Int) -> LogValue {
        .string(LogString.truncateUTF8(value, maxBytes: maxBytes))
    }

    public static func error(_ value: Error) -> LogValue {
        let nsError = value as NSError
        return .object([
            "type": .string(String(describing: type(of: value))),
            "message": .string(String(describing: value)),
            "code": .int(Int64(nsError.code)),
            "domain": .string(nsError.domain)
        ])
    }

    public static func error(_ value: Error, maxBytes: Int) -> LogValue {
        let nsError = value as NSError
        let message = LogString.truncateUTF8(String(describing: value), maxBytes: maxBytes)
        return .object([
            "type": .string(String(describing: type(of: value))),
            "message": .string(message),
            "code": .int(Int64(nsError.code)),
            "domain": .string(nsError.domain)
        ])
    }

    public static func encodable<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) -> LogValue {
        do {
            let data = try encoder.encode(value)
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            return fromJSON(obj)
        } catch {
            return .string(String(describing: value))
        }
    }

    func redacted(using matcher: RedactionMatcher, path: [String]) -> LogValue {
        switch self {
        case .array(let values):
            return .array(values.map { $0.redacted(using: matcher, path: path) })
        case .object(let dict):
            var out: [String: LogValue] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict {
                let nextPath = path + [key]
                if matcher.matches(key: key, path: nextPath) {
                    out[key] = .string("<redacted>")
                } else {
                    out[key] = value.redacted(using: matcher, path: nextPath)
                }
            }
            return .object(out)
        default:
            return self
        }
    }

    private static func fromJSON(_ object: Any) -> LogValue {
        switch object {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(Int64(value))
        case let value as Int64:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as [Any]:
            return .array(value.map { fromJSON($0) })
        case let value as [String: Any]:
            var out: [String: LogValue] = [:]
            out.reserveCapacity(value.count)
            for (key, val) in value {
                out[key] = fromJSON(val)
            }
            return .object(out)
        default:
            return .string(String(describing: object))
        }
    }
}

enum LogString {
    static func truncateUTF8(_ value: String, maxBytes: Int) -> String {
        let limit = max(0, maxBytes)
        if value.utf8.count <= limit { return value }
        let prefix = value.utf8.prefix(limit)
        let truncated = String(decoding: prefix, as: UTF8.self)
        return truncated + "...(truncated)"
    }
}

public typealias LogMetadata = [String: LogValue]

/// Caller source location.
/// Call-site information for a log event.
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
/// Execution context for a log event (thread, queue, priority).
public struct ExecutionContext: Sendable, Codable {
    public var isMainThread: Bool
    public var threadName: String?
    public var queueLabel: String?
    public var taskPriority: String?
    public var processID: Int32
    public var threadID: UInt64?

    public init(
        isMainThread: Bool,
        threadName: String?,
        queueLabel: String?,
        taskPriority: String?,
        processID: Int32,
        threadID: UInt64?
    ) {
        self.isMainThread = isMainThread
        self.threadName = threadName
        self.queueLabel = queueLabel
        self.taskPriority = taskPriority
        self.processID = processID
        self.threadID = threadID
    }

    public static func capture() -> ExecutionContext {
        let isMain = Thread.isMainThread
        let tname = Thread.current.name

        let labelCString = __dispatch_queue_get_label(nil)
        let label = String(cString: labelCString)

        // Task priority is meaningful when called from async contexts; otherwise it's still safe.
        let priority = String(describing: Task.currentPriority)

        let pid = getpid()
        let tid = currentThreadID()

        return ExecutionContext(
            isMainThread: isMain,
            threadName: tname,
            queueLabel: label.isEmpty ? nil : label,
            taskPriority: priority,
            processID: pid,
            threadID: tid
        )
    }

    private static func currentThreadID() -> UInt64? {
        #if canImport(Darwin)
        var tid: UInt64 = 0
        if pthread_threadid_np(nil, &tid) == 0 {
            return tid
        }
        #endif
        return nil
    }
}

/// Log event schema (JSONL encoding uses this).
/// A structured log event (JSONL schema).
public struct LogEvent: Sendable, Codable {
    public static let schemaVersion: Int = 1

    public var schemaVersion: Int
    public var id: UUID
    public var timestamp: Date
    public var uptimeNanoseconds: UInt64?
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
        uptimeNanoseconds: UInt64? = DispatchTime.now().uptimeNanoseconds,
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
        self.uptimeNanoseconds = uptimeNanoseconds
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
/// Context bound to a logger or task (tags + metadata).
public struct LogContext: Sendable, Codable {
    public var tags: Set<LogTag>
    public var metadata: LogMetadata

    public enum MergePolicy: String, Sendable, Codable {
        case keepExisting
        case replaceWithNew
    }

    public init(tags: Set<LogTag> = [], metadata: LogMetadata = [:]) {
        self.tags = tags
        self.metadata = metadata
    }

    public static let empty = LogContext()

    public func merging(_ other: LogContext, policy: MergePolicy = .replaceWithNew) -> LogContext {
        var out = self
        out.tags.formUnion(other.tags)
        switch policy {
        case .replaceWithNew:
            out.metadata.merge(other.metadata, uniquingKeysWith: { _, new in new })
        case .keepExisting:
            out.metadata.merge(other.metadata, uniquingKeysWith: { existing, _ in existing })
        }
        return out
    }
}

/// Filtering rules for the logging pipeline.
/// `includeTags` acts like a focused debug allowlist: if not empty,
/// an event must contain at least one of the includeTags to pass.
/// Filtering rules for the logging pipeline.
public struct LogFilter: Sendable, Codable {
    public var minimumLevel: LogLevel
    public var includeCategories: Set<String>
    public var excludeCategories: Set<String>
    public var includeTags: Set<String>
    public var excludeTags: Set<String>

    public var sampling: Sampling

    public init(
        minimumLevel: LogLevel,
        includeCategories: Set<String> = [],
        excludeCategories: Set<String> = [],
        includeTags: Set<String> = [],
        excludeTags: Set<String> = [],
        sampling: Sampling = .none
    ) {
        self.minimumLevel = minimumLevel
        self.includeCategories = includeCategories
        self.excludeCategories = excludeCategories
        self.includeTags = includeTags
        self.excludeTags = excludeTags
        self.sampling = sampling
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

        let rate = sampling.rate
        if rate <= 0 { return false }
        if rate < 1, Double.random(in: 0..<1) >= rate { return false }

        return true
    }

    public struct Sampling: Sendable, Codable {
        public var rate: Double

        public init(rate: Double) {
            self.rate = max(0, min(1, rate))
        }

        public static let none = Sampling(rate: 1)
    }
}

/// Text vs JSON output for stdout logging.
public enum StdoutFormat: String, Sendable, Codable {
    case text
    case json
}

/// Formats log events for text sinks.
public protocol LogFormatter: Sendable {
    func format(_ event: LogEvent, configuration: LogConfiguration) -> String
}

/// Default formatter for text output.
public struct DefaultLogFormatter: LogFormatter {
    public init() {}

    public func format(_ event: LogEvent, configuration: LogConfiguration) -> String {
        LogFormatting.lineText(for: event, configuration: configuration)
    }
}

/// Text output style for stdout.
public enum LogTextStyle: String, Sendable, Codable {
    /// `ts level subsystem/category message tags meta src`
    case compact
    /// More verbose text format (includes execution context if present).
    case verbose
}

/// Global configuration (filtering + formatting + redaction).
/// Global logging configuration and formatting options.
public struct LogConfiguration: Sendable, Codable {
    public var filter: LogFilter

    public var oslogPrivacy: LogPrivacy
    public var includeSourceLocation: Bool
    public var includeExecutionContext: Bool

    public var textStyle: LogTextStyle

    /// Metadata keys/patterns to remove or replace before any sink sees them.
    /// Supports exact keys and simple wildcards like `auth.*` or `*.token`.
    public var redactedMetadataKeys: Set<String>

    /// Merge policy for metadata when multiple contexts provide the same key.
    public var metadataMergePolicy: LogContext.MergePolicy

    /// AsyncStream buffer capacity (older events dropped when full).
    public var streamBufferCapacity: Int

    /// Per-category minimum level overrides.
    public var categoryMinimumLevels: [String: LogLevel]

    /// Per-tag minimum level overrides.
    public var tagMinimumLevels: [String: LogLevel]

    /// Global rate limit (token bucket). Nil means disabled.
    public var rateLimit: RateLimit?

    /// Per-category rate limits (token bucket).
    public var categoryRateLimits: [String: RateLimit]

    /// Per-tag rate limits (token bucket).
    public var tagRateLimits: [String: RateLimit]

    /// Optional maximum UTF-8 byte length for log messages.
    public var maxMessageBytes: Int?

    /// Convenience: set a per-tag minimum level.
    public mutating func setTagMinimumLevel(_ level: LogLevel, for tag: LogTag) {
        tagMinimumLevels[tag.rawValue] = level
    }

    /// Convenience: set a per-tag rate limit.
    public mutating func setTagRateLimit(_ limit: RateLimit, for tag: LogTag) {
        tagRateLimits[tag.rawValue] = limit
    }

    /// Convenience: set a per-category minimum level.
    public mutating func setCategoryMinimumLevel(_ level: LogLevel, for category: String) {
        categoryMinimumLevels[category] = level
    }

    /// Convenience: set a per-category rate limit.
    public mutating func setCategoryRateLimit(_ limit: RateLimit, for category: String) {
        categoryRateLimits[category] = limit
    }

    /// Sources for applying configuration overrides.
    public enum OverrideSource: Sendable {
        case environment(prefix: String = "MODERNSWIFTLOGGER_")
    }

    /// Apply overrides in order; later sources win.
    public mutating func applyOverrides(_ sources: [OverrideSource]) {
        for source in sources {
            switch source {
            case .environment(let prefix):
                applyEnvironment(prefix: prefix)
            }
        }
    }

    /// Return a copy with overrides applied.
    public func applyingOverrides(_ sources: [OverrideSource]) -> LogConfiguration {
        var copy = self
        copy.applyOverrides(sources)
        return copy
    }

    public init(
        filter: LogFilter,
        oslogPrivacy: LogPrivacy,
        includeSourceLocation: Bool,
        includeExecutionContext: Bool,
        textStyle: LogTextStyle,
        redactedMetadataKeys: Set<String>,
        metadataMergePolicy: LogContext.MergePolicy,
        streamBufferCapacity: Int,
        categoryMinimumLevels: [String: LogLevel],
        tagMinimumLevels: [String: LogLevel] = [:],
        rateLimit: RateLimit?,
        categoryRateLimits: [String: RateLimit],
        tagRateLimits: [String: RateLimit] = [:],
        maxMessageBytes: Int? = nil
    ) {
        self.filter = filter
        self.oslogPrivacy = oslogPrivacy
        self.includeSourceLocation = includeSourceLocation
        self.includeExecutionContext = includeExecutionContext
        self.textStyle = textStyle
        self.redactedMetadataKeys = redactedMetadataKeys
        self.metadataMergePolicy = metadataMergePolicy
        self.streamBufferCapacity = max(16, streamBufferCapacity)
        self.categoryMinimumLevels = categoryMinimumLevels
        self.tagMinimumLevels = tagMinimumLevels
        self.rateLimit = rateLimit
        self.categoryRateLimits = categoryRateLimits
        self.tagRateLimits = tagRateLimits
        self.maxMessageBytes = maxMessageBytes
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

        #if os(watchOS)
        let buffer = 256
        #else
        let buffer = 1024
        #endif

        return LogConfiguration(
            filter: LogFilter(minimumLevel: minLevel),
            oslogPrivacy: privacy,
            includeSourceLocation: includeSource,
            includeExecutionContext: false,
            textStyle: .compact,
            redactedMetadataKeys: [],
            metadataMergePolicy: .replaceWithNew,
            streamBufferCapacity: buffer,
            categoryMinimumLevels: [:],
            tagMinimumLevels: [:],
            rateLimit: nil,
            categoryRateLimits: [:],
            tagRateLimits: [:],
            maxMessageBytes: nil
        )
    }

    /// Recommended defaults for production + debugging.
    public static func recommended(
        minLevel: LogLevel = .info,
        includeSourceLocation: Bool = false,
        includeExecutionContext: Bool = false
    ) -> LogConfiguration {
        let config = LogConfiguration(
            filter: LogFilter(minimumLevel: minLevel),
            oslogPrivacy: .private,
            includeSourceLocation: includeSourceLocation,
            includeExecutionContext: includeExecutionContext,
            textStyle: .compact,
            redactedMetadataKeys: ["password", "token", "authorization"],
            metadataMergePolicy: .replaceWithNew,
            streamBufferCapacity: 1024,
            categoryMinimumLevels: [:],
            tagMinimumLevels: [:],
            rateLimit: nil,
            categoryRateLimits: [:],
            tagRateLimits: [:],
            maxMessageBytes: 4096
        )
        return config
    }

    private mutating func applyEnvironment(prefix: String) {
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

        if let s = env["\(prefix)SAMPLE_RATE"], let rate = Double(s) {
            filter.sampling = LogFilter.Sampling(rate: rate)
        }

        if let s = env["\(prefix)CATEGORY_LEVELS"] {
            categoryMinimumLevels = parseCategoryLevels(s)
        }
        if let s = env["\(prefix)TAG_LEVELS"] {
            tagMinimumLevels = parseTagLevels(s)
        }

        if let s = env["\(prefix)RATE_LIMIT"], let n = Int(s), n > 0 {
            rateLimit = RateLimit(eventsPerSecond: n)
        }

        if let s = env["\(prefix)CATEGORY_RATE_LIMITS"] {
            categoryRateLimits = parseCategoryRateLimits(s)
        }
        if let s = env["\(prefix)TAG_RATE_LIMITS"] {
            tagRateLimits = parseTagRateLimits(s)
        }

        if let s = env["\(prefix)MERGE_POLICY"]?.lowercased(),
           let policy = LogContext.MergePolicy(rawValue: s) {
            metadataMergePolicy = policy
        }

        if let s = env["\(prefix)MAX_MESSAGE_BYTES"], let n = Int(s), n > 0 {
            maxMessageBytes = n
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

    private func parseCategoryLevels(_ s: String) -> [String: LogLevel] {
        var out: [String: LogLevel] = [:]
        let pairs = s.split(separator: ",")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let lvl = LogLevel(val), !key.isEmpty {
                out[key] = lvl
            }
        }
        return out
    }

    private func parseTagLevels(_ s: String) -> [String: LogLevel] {
        parseCategoryLevels(s)
    }

    private func parseCategoryRateLimits(_ s: String) -> [String: RateLimit] {
        var out: [String: RateLimit] = [:]
        let pairs = s.split(separator: ",")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(val), n > 0, !key.isEmpty {
                out[key] = RateLimit(eventsPerSecond: n)
            }
        }
        return out
    }

    private func parseTagRateLimits(_ s: String) -> [String: RateLimit] {
        parseCategoryRateLimits(s)
    }
}

public extension LogConfiguration {
    func allows(level: LogLevel, category: String, tags: Set<LogTag>, applySampling: Bool = true) -> Bool {
        if !filter.includeCategories.isEmpty, !filter.includeCategories.contains(category) {
            return false
        }
        if filter.excludeCategories.contains(category) {
            return false
        }

        var minLevel = categoryMinimumLevels[category] ?? filter.minimumLevel
        if !tagMinimumLevels.isEmpty {
            for tag in tags {
                if let tagLevel = tagMinimumLevels[tag.rawValue], tagLevel > minLevel {
                    minLevel = tagLevel
                }
            }
        }
        guard level >= minLevel else { return false }

        let tagStrings = Set(tags.map(\.rawValue))
        if !filter.includeTags.isEmpty, filter.includeTags.isDisjoint(with: tagStrings) {
            return false
        }
        if !filter.excludeTags.isEmpty, !filter.excludeTags.isDisjoint(with: tagStrings) {
            return false
        }

        if applySampling {
            let rate = filter.sampling.rate
            if rate <= 0 { return false }
            if rate < 1, Double.random(in: 0..<1) >= rate { return false }
        }

        return true
    }
}

/// Token-bucket rate limit configuration.
public struct RateLimit: Sendable, Codable {
    public var eventsPerSecond: Int
    public var burst: Int

    public init(eventsPerSecond: Int, burst: Int? = nil) {
        let rate = max(1, eventsPerSecond)
        self.eventsPerSecond = rate
        self.burst = max(1, burst ?? rate)
    }
}

/// Snapshot of sink error counts and last error message.
public struct SinkErrorSnapshot: Sendable, Codable, Hashable {
    public var sink: String
    public var count: UInt64
    public var lastTimestamp: Date?
    public var lastError: String?

    public init(sink: String, count: UInt64, lastTimestamp: Date?, lastError: String?) {
        self.sink = sink
        self.count = count
        self.lastTimestamp = lastTimestamp
        self.lastError = lastError
    }
}

struct RedactionMatcher {
    private let exactKeys: Set<String>
    private let keyPatterns: [WildcardPattern]
    private let pathPatterns: [[WildcardPattern]]
    private let pathStringPatterns: [WildcardPattern]

    init(keys: Set<String>) {
        let lowered = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var exact: Set<String> = []
        var keyPatterns: [WildcardPattern] = []
        var pathPatterns: [[WildcardPattern]] = []
        var pathStringPatterns: [WildcardPattern] = []

        for key in lowered where !key.isEmpty {
            if key.contains(".") {
                let segments = key.split(separator: ".").map { WildcardPattern(String($0)) }
                pathPatterns.append(segments)
                pathStringPatterns.append(WildcardPattern(key))
            } else if key.contains("*") {
                keyPatterns.append(WildcardPattern(key))
            } else {
                exact.insert(key)
            }
        }

        self.exactKeys = exact
        self.keyPatterns = keyPatterns
        self.pathPatterns = pathPatterns
        self.pathStringPatterns = pathStringPatterns
    }

    func matches(key: String, path: [String]) -> Bool {
        let keyLower = key.lowercased()
        if exactKeys.contains(keyLower) { return true }
        if keyPatterns.contains(where: { $0.matches(keyLower) }) { return true }

        let pathLower = path.map { $0.lowercased() }
        let fullPath = pathLower.joined(separator: ".")
        if pathStringPatterns.contains(where: { $0.matches(fullPath) }) {
            return true
        }
        for pattern in pathPatterns {
            if matchesPath(pattern: pattern, path: pathLower) {
                return true
            }
        }

        return false
    }

    private func matchesPath(pattern: [WildcardPattern], path: [String]) -> Bool {
        if pattern.count == path.count {
            return segmentsMatch(pattern, path)
        }

        if let first = pattern.first, first.isMatchAll {
            let tail = Array(pattern.dropFirst())
            if path.count >= pattern.count, tail.count <= path.count {
                let suffix = Array(path.suffix(tail.count))
                if segmentsMatch(tail, suffix) { return true }
            }
        }

        if let last = pattern.last, last.isMatchAll {
            let head = Array(pattern.dropLast())
            if path.count >= pattern.count, head.count <= path.count {
                let prefix = Array(path.prefix(head.count))
                if segmentsMatch(head, prefix) { return true }
            }
        }

        return false
    }

    private func segmentsMatch(_ pattern: [WildcardPattern], _ path: [String]) -> Bool {
        for (segment, value) in zip(pattern, path) {
            if !segment.matches(value) {
                return false
            }
        }
        return true
    }

    private struct WildcardPattern {
        let raw: String
        let parts: [Substring]
        let startsWithWildcard: Bool
        let endsWithWildcard: Bool

        init(_ raw: String) {
            self.raw = raw
            self.parts = raw.split(separator: "*", omittingEmptySubsequences: true)
            self.startsWithWildcard = raw.hasPrefix("*")
            self.endsWithWildcard = raw.hasSuffix("*")
        }

        var isMatchAll: Bool {
            raw == "*"
        }

        func matches(_ value: String) -> Bool {
            if raw == "*" { return true }
            guard !parts.isEmpty else { return value == raw }

            var searchStart = value.startIndex
            for (index, part) in parts.enumerated() {
                guard let range = value.range(of: part, range: searchStart..<value.endIndex) else {
                    return false
                }
                if index == 0, !startsWithWildcard, range.lowerBound != value.startIndex {
                    return false
                }
                searchStart = range.upperBound
            }

            if !endsWithWildcard {
                return searchStart == value.endIndex
            }
            return true
        }
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
                extra.append("pid=\(exec.processID)")
                if let tid = exec.threadID { extra.append("tid=\(tid)") }
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

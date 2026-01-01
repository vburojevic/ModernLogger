import Foundation
import Dispatch
#if canImport(Compression)
import Compression
#endif
#if canImport(OSLog)
import OSLog
#endif

// MARK: - LogSink protocol + built-in sinks

/// A destination for log events (stdout, file, OSLog, etc).
public protocol LogSink: Sendable {
    func emit(_ event: LogEvent) async
    func flush() async

    var filter: LogFilter? { get }
    var redactionKeys: Set<String>? { get }
}

/// Callback for sink errors (I/O, encoding failures, etc).
public typealias LogSinkErrorHandler = @Sendable (Error) -> Void

public extension LogSink {
    func flush() async { /* optional */ }
    var filter: LogFilter? { nil }
    var redactionKeys: Set<String>? { nil }
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
/// Native Unified Logging sink.
public actor OSLogSink: LogSink {
    private struct Key: Hashable {
        var subsystem: String
        var category: String
    }

    private let privacy: LogPrivacy
    public let filter: LogFilter?
    private var cache: [Key: Logger] = [:]

    public init(privacy: LogPrivacy = {
        #if DEBUG
        return .public
        #else
        return .private
        #endif
    }(), filter: LogFilter? = nil) {
        self.privacy = privacy
        self.filter = filter
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
/// Stdout/stderr sink (text or JSONL).
public typealias LogLineWriter = @Sendable (_ line: String, _ isError: Bool) throws -> Void

public actor StdoutSink: LogSink {
    private let format: StdoutFormat
    private let configuration: LogConfiguration
    private let formatter: any LogFormatter
    public let filter: LogFilter?
    public let redactionKeys: Set<String>?
    private let onError: LogSinkErrorHandler?
    private let writer: LogLineWriter

    private let encoder: JSONEncoder

    public init(
        format: StdoutFormat = .text,
        configuration: LogConfiguration,
        formatter: any LogFormatter = DefaultLogFormatter(),
        filter: LogFilter? = nil,
        redactionKeys: Set<String>? = nil,
        onError: LogSinkErrorHandler? = nil,
        writer: LogLineWriter? = nil
    ) {
        self.format = format
        self.configuration = configuration
        self.formatter = formatter
        self.filter = filter
        self.redactionKeys = redactionKeys
        self.onError = onError
        self.writer = writer ?? StdoutSink.defaultWriter
        self.encoder = StdoutSink.makeJSONEncoder(deterministic: configuration.deterministicJSON)
    }

    public func emit(_ event: LogEvent) async {
        let line: String
        switch format {
        case .text:
            line = formatter.format(event, configuration: configuration)
        case .json, .jsonl:
            do {
                let data = try encoder.encode(event)
                line = String(decoding: data, as: UTF8.self)
            } catch {
                onError?(error)
                line = #"{"schemaVersion":1,"level":"error","message":"StdoutSink JSON encode failed","error":"\#(String(describing: error))"}"#
            }
        }

        // Write to stdout/stderr (errors -> stderr).
        let isError = event.level >= .error
        do {
            try writer(line + "\n", isError)
        } catch {
            onError?(error)
        }
    }

    private static func makeJSONEncoder(deterministic: Bool) -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if deterministic {
            enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        } else {
            enc.outputFormatting = [.withoutEscapingSlashes]
        }
        return enc
    }

    private static func defaultWriter(_ line: String, _ isError: Bool) throws {
        let target = isError ? FileHandle.standardError : FileHandle.standardOutput
        if let data = line.data(using: .utf8) {
            try target.write(contentsOf: data)
        }
    }
}

/// JSONL file sink (one JSON object per line).
/// This is intentionally "agent-friendly" (easy to parse, grep, and attach to bug reports).
/// JSONL file sink with rotation + buffering.
public actor FileSink: LogSink {
    public enum FileProtection: String, Sendable, Codable {
        case none
        case complete
        case completeUnlessOpen
        case completeUntilFirstUserAuthentication

        var fileProtectionType: FileProtectionType? {
            switch self {
            case .none: return FileProtectionType.none
            case .complete: return .complete
            case .completeUnlessOpen: return .completeUnlessOpen
            case .completeUntilFirstUserAuthentication: return .completeUntilFirstUserAuthentication
            }
        }
    }

    public struct FileOptions: Sendable {
        public var protection: FileProtection?
        public var excludeFromBackup: Bool

        public init(protection: FileProtection? = nil, excludeFromBackup: Bool = true) {
            self.protection = protection
            self.excludeFromBackup = excludeFromBackup
        }
    }

    public struct Rotation: Sendable, Codable {
        public var maxBytes: Int
        public var maxFiles: Int
        public var maxAgeSeconds: TimeInterval
        public var compression: Compression

        public init(
            maxBytes: Int = 10 * 1024 * 1024,
            maxFiles: Int = 5,
            maxAgeSeconds: TimeInterval = 0,
            compression: Compression = .none
        ) {
            self.maxBytes = maxBytes <= 0 ? 0 : max(256 * 1024, maxBytes)
            self.maxFiles = max(1, maxFiles)
            self.maxAgeSeconds = max(0, maxAgeSeconds)
            self.compression = compression
        }
    }

    public enum Compression: String, Sendable, Codable {
        case none
        case zlib
        case lz4
        case lzfse
        case lzma

        var fileExtension: String? {
            switch self {
            case .none: return nil
            case .zlib: return "zlib"
            case .lz4: return "lz4"
            case .lzfse: return "lzfse"
            case .lzma: return "lzma"
            }
        }
    }

    public struct Buffering: Sendable, Codable {
        public var maxBytes: Int
        public var flushInterval: TimeInterval

        public init(maxBytes: Int = 64 * 1024, flushInterval: TimeInterval = 2) {
            self.maxBytes = max(4 * 1024, maxBytes)
            self.flushInterval = max(0, flushInterval)
        }
    }

    public let url: URL
    public let filter: LogFilter?
    public let redactionKeys: Set<String>?
    private let rotation: Rotation
    private let buffering: Buffering
    private let fileOptions: FileOptions
    private let onError: LogSinkErrorHandler?

    private var fileHandle: FileHandle?
    private var currentSizeBytes: UInt64 = 0
    private var currentCreatedAt: Date?
    private var buffer = Data()
    private var flushTask: Task<Void, Never>?
    private var rotationCounter: UInt64 = 0

    private let encoder: JSONEncoder
    private let deterministicJSON: Bool

    public init(
        url: URL,
        rotation: Rotation = Rotation(),
        buffering: Buffering = Buffering(),
        filter: LogFilter? = nil,
        redactionKeys: Set<String>? = nil,
        fileOptions: FileOptions = FileOptions(),
        deterministicJSON: Bool = false,
        onError: LogSinkErrorHandler? = nil
    ) {
        self.url = url
        self.rotation = rotation
        self.buffering = buffering
        self.filter = filter
        self.redactionKeys = redactionKeys
        self.fileOptions = fileOptions
        self.onError = onError
        self.deterministicJSON = deterministicJSON
        self.encoder = FileSink.makeJSONEncoder(deterministic: deterministicJSON)
    }

    public init(
        url: URL,
        configuration: LogConfiguration,
        rotation: Rotation = Rotation(),
        buffering: Buffering = Buffering(),
        filter: LogFilter? = nil,
        redactionKeys: Set<String>? = nil,
        fileOptions: FileOptions = FileOptions(),
        onError: LogSinkErrorHandler? = nil
    ) {
        self.init(
            url: url,
            rotation: rotation,
            buffering: buffering,
            filter: filter,
            redactionKeys: redactionKeys,
            fileOptions: fileOptions,
            deterministicJSON: configuration.deterministicJSON,
            onError: onError
        )
    }

    public static func defaultURL(fileName: String = "modernswiftlogger.jsonl") -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(fileName, isDirectory: false)
    }

    public func emit(_ event: LogEvent) async {
        do {
            try ensureOpen()
            let data = try encoder.encode(event)
            var line = Data()
            line.append(data)
            line.append(0x0A)

            try rotateIfNeeded(adding: buffer.count + line.count)

            buffer.append(line)
            if buffer.count >= buffering.maxBytes {
                try flushBuffer()
            } else {
                scheduleFlushIfNeeded()
            }
        } catch {
            // If file logging fails, we intentionally do not crash the app.
            // You can still see OSLog/Stdout sinks if configured.
            onError?(error)
        }
    }

    public func flush() async {
        do {
            try flushBuffer()
            try fileHandle?.synchronize()
        } catch {
            onError?(error)
        }
    }

    public func clear() async {
        do {
            try fileHandle?.close()
        } catch {
            onError?(error)
        }
        fileHandle = nil
        currentSizeBytes = 0
        currentCreatedAt = nil
        buffer.removeAll(keepingCapacity: true)
        flushTask?.cancel()
        flushTask = nil
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            onError?(error)
        }
    }

    // MARK: - Internals

    private func ensureOpen() throws {
        if fileHandle != nil { return }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            currentCreatedAt = Date()
        }
        applyFileOptions(to: url)

        let handle = try FileHandle(forWritingTo: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            currentSizeBytes = (attrs[.size] as? UInt64) ?? 0
            if currentCreatedAt == nil {
                currentCreatedAt = (attrs[.creationDate] as? Date) ?? Date()
            }
        }
        _ = try handle.seekToEnd()
        fileHandle = handle
    }

    private func rotateIfNeeded(adding bytes: Int) throws {
        let sizeRotationEnabled = rotation.maxBytes > 0
        let ageRotationEnabled = rotation.maxAgeSeconds > 0
        guard sizeRotationEnabled || ageRotationEnabled else { return }

        let projected = currentSizeBytes + UInt64(bytes)
        let shouldRotateForSize = sizeRotationEnabled && projected > UInt64(rotation.maxBytes)
        let shouldRotateForAge: Bool
        if ageRotationEnabled, let createdAt = currentCreatedAt {
            shouldRotateForAge = Date().timeIntervalSince(createdAt) >= rotation.maxAgeSeconds
        } else {
            shouldRotateForAge = false
        }

        guard shouldRotateForSize || shouldRotateForAge else { return }

        try flushBuffer()

        // Close current file first.
        try fileHandle?.close()
        fileHandle = nil

        // Move current file to a timestamped name.
        let ts = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "jsonl" : url.pathExtension
        rotationCounter &+= 1
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(ts)-\(rotationCounter).\(ext)")

        // If move fails (e.g. file missing), just continue and recreate.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: url, to: rotated)
        }

        let finalRotated = compressIfNeeded(rotated)
        applyFileOptions(to: rotated)
        applyFileOptions(to: finalRotated)

        // Purge old rotations.
        purgeOldRotations(baseName: baseName, ext: ext)
        _ = finalRotated

        // Re-open a fresh file.
        try ensureOpen()
        currentSizeBytes = 0
        currentCreatedAt = Date()
    }

    private func applyFileOptions(to targetURL: URL) {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }
        if let protection = fileOptions.protection?.fileProtectionType {
            do {
                try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: targetURL.path)
            } catch {
                onError?(error)
            }
        }
        if fileOptions.excludeFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                var fileURL = targetURL
                try fileURL.setResourceValues(values)
            } catch {
                onError?(error)
            }
        }
    }

    private static func makeJSONEncoder(deterministic: Bool) -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if deterministic {
            enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        } else {
            enc.outputFormatting = [.withoutEscapingSlashes]
        }
        return enc
    }

    private func purgeOldRotations(baseName: String, ext: String) {
        let dir = url.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }

        let rotated = items.filter { item in
            guard item.lastPathComponent.hasPrefix(baseName + "-") else { return false }
            if item.pathExtension == ext { return true }
            if let compressionExt = rotation.compression.fileExtension, item.pathExtension == compressionExt {
                let base = item.deletingPathExtension().pathExtension
                return base == ext
            }
            return false
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

    private func flushBuffer() throws {
        guard !buffer.isEmpty else { return }
        try ensureOpen()
        try fileHandle?.write(contentsOf: buffer)
        currentSizeBytes += UInt64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    private func scheduleFlushIfNeeded() {
        guard buffering.flushInterval > 0 else { return }
        guard flushTask == nil else { return }
        let interval = buffering.flushInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self else { return }
            await self.flush()
            await self.clearFlushTask()
        }
    }

    private func clearFlushTask() {
        flushTask = nil
    }

    private func compressIfNeeded(_ file: URL) -> URL {
        guard rotation.compression != .none else { return file }
        #if canImport(Compression)
        guard let outURL = compressFile(file, algorithm: rotation.compression) else { return file }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            onError?(error)
        }
        return outURL
        #else
        return file
        #endif
    }

    #if canImport(Compression)
    private func compressFile(_ file: URL, algorithm: Compression) -> URL? {
        let algo: compression_algorithm
        switch algorithm {
        case .none: return file
        case .zlib: algo = COMPRESSION_ZLIB
        case .lz4: algo = COMPRESSION_LZ4
        case .lzfse: algo = COMPRESSION_LZFSE
        case .lzma: algo = COMPRESSION_LZMA
        }

        let outExt = algorithm.fileExtension ?? "compressed"
        let outURL = file.appendingPathExtension(outExt)
        guard compressFileStreaming(src: file, dst: outURL, algorithm: algo) else {
            return nil
        }
        return outURL
    }

    private func compressFileStreaming(src: URL, dst: URL, algorithm: compression_algorithm) -> Bool {
        guard let input = InputStream(url: src),
              let output = OutputStream(url: dst, append: false) else {
            return false
        }

        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        let srcBufferSize = 64 * 1024
        let dstBufferSize = 64 * 1024
        let srcBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: srcBufferSize)
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstBufferSize)
        defer {
            srcBuffer.deallocate()
            dstBuffer.deallocate()
        }

        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, algorithm)
        guard status != COMPRESSION_STATUS_ERROR else { return false }
        defer { compression_stream_destroy(&stream) }

        var readCount = input.read(srcBuffer, maxLength: srcBufferSize)
        var done = readCount == 0

        while readCount >= 0 {
            stream.src_ptr = UnsafePointer(srcBuffer)
            stream.src_size = readCount

            let flags = done ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            repeat {
                stream.dst_ptr = dstBuffer
                stream.dst_size = dstBufferSize

                status = compression_stream_process(&stream, flags)
                if status == COMPRESSION_STATUS_ERROR { return false }

                let produced = dstBufferSize - stream.dst_size
                if produced > 0 {
                    let written = output.write(dstBuffer, maxLength: produced)
                    if written != produced { return false }
                }
            } while stream.src_size > 0

            if status == COMPRESSION_STATUS_END { return true }

            readCount = input.read(srcBuffer, maxLength: srcBufferSize)
            done = readCount == 0
        }

        return false
    }
    #endif
}

/// In-memory ring buffer sink (useful for tests and attach recent logs flows).
/// In-memory ring buffer sink.
public actor InMemorySink: LogSink {
    private let capacity: Int
    private var buffer: [LogEvent] = []
    public let filter: LogFilter?
    public let redactionKeys: Set<String>?

    public init(capacity: Int = 512, filter: LogFilter? = nil, redactionKeys: Set<String>? = nil) {
        self.capacity = max(1, capacity)
        self.buffer.reserveCapacity(self.capacity)
        self.filter = filter
        self.redactionKeys = redactionKeys
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

/// Test sink with awaitable helpers.
public actor TestSink: LogSink {
    public let filter: LogFilter?
    public let redactionKeys: Set<String>?
    private var buffer: [LogEvent] = []

    public init(filter: LogFilter? = nil, redactionKeys: Set<String>? = nil) {
        self.filter = filter
        self.redactionKeys = redactionKeys
    }

    public func emit(_ event: LogEvent) async {
        buffer.append(event)
    }

    public func next(timeoutSeconds: Double = 1.0) async -> LogEvent? {
        let start = Date()
        while buffer.isEmpty, Date().timeIntervalSince(start) < timeoutSeconds {
            let remaining = timeoutSeconds - Date().timeIntervalSince(start)
            let sleepSeconds = min(0.05, max(0, remaining))
            if sleepSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        }
        return buffer.isEmpty ? nil : buffer.removeFirst()
    }

    public func waitForCount(_ count: Int, timeoutSeconds: Double = 1.0) async -> [LogEvent] {
        let start = Date()
        while buffer.count < count, Date().timeIntervalSince(start) < timeoutSeconds {
            let remaining = timeoutSeconds - Date().timeIntervalSince(start)
            let sleepSeconds = min(0.05, max(0, remaining))
            if sleepSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        }
        if buffer.count <= count {
            let out = buffer
            buffer.removeAll(keepingCapacity: true)
            return out
        }
        let out = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    public func snapshot() async -> [LogEvent] {
        buffer
    }

    public func clear() async {
        buffer.removeAll(keepingCapacity: true)
    }
}

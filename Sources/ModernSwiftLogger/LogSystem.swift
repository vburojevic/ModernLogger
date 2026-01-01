import Foundation
import Dispatch

// MARK: - LogSystem (global pipeline + config)

/// Global logging pipeline, configuration, and sinks.
public enum LogSystem {
    // Task-local context.
    public enum TaskLocalContext {
        @TaskLocal public static var context: LogContext = .empty
    }

    /// Run an async operation with additional task-local tags/metadata.
    public static func withContext<T>(
        tags: Set<LogTag> = [],
        metadata: LogMetadata = [:],
        mergePolicy: LogContext.MergePolicy? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        let extra = LogContext(tags: tags, metadata: metadata)
        let policy = mergePolicy ?? LogSystem.snapshot().metadataMergePolicy
        return try await TaskLocalContext.$context.withValue(TaskLocalContext.context.merging(extra, policy: policy)) {
            try await operation()
        }
    }

    /// Global default subsystem.
    public static var defaultSubsystem: String { runtime.defaultSubsystem }

    /// Override the default subsystem used by new `Log` instances.
    /// Pass `nil` to clear the override.
    public static func setDefaultSubsystem(_ subsystem: String?) {
        runtime.setDefaultSubsystem(subsystem)
    }

    /// Current dropped event count (buffer overflow, shutdown, etc).
    public static var droppedEventCount: UInt64 { runtime.droppedEventCount }

    /// Bootstraps the logging system with explicit config and sinks.
    /// Calling bootstrap multiple times replaces config + sinks (idempotent).
    public static func bootstrap(configuration: LogConfiguration, sinks: [any LogSink]) {
        runtime.bootstrap(configuration: configuration, sinks: sinks)
    }

    /// Bootstraps with explicit configuration and ordered overrides.
    /// Overrides are applied in order; later sources win.
    public static func bootstrap(
        configuration: LogConfiguration,
        overrides: [LogConfiguration.OverrideSource],
        sinks: [any LogSink]
    ) {
        var config = configuration
        config.applyOverrides(overrides)
        bootstrap(configuration: config, sinks: sinks)
    }

    /// Convenience: bootstrap with recommended defaults and OSLog sink.
    public static func bootstrapRecommended() {
        let config = LogConfiguration.recommended()
        let sinks: [any LogSink] = {
            #if canImport(OSLog)
            if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, visionOS 1.0, *) {
                return [OSLogSink(privacy: config.oslogPrivacy)]
            }
            #endif
            return [StdoutSink(format: .text, configuration: config)]
        }()
        bootstrap(configuration: config, sinks: sinks)
    }

    /// Convenience: CI-friendly defaults (stdout JSON).
    public static func bootstrapRecommendedForCI() {
        let config = LogConfiguration.recommended(minLevel: .debug)
        let sink = StdoutSink(format: .json, configuration: config)
        bootstrap(configuration: config, sinks: [sink])
    }

    /// Bootstraps the logging system only if it isn't already running.
    public static func bootstrapIfNeeded() {
        runtime.bootstrapIfNeeded()
    }


    /// Add a sink at runtime.
    public static func addSink(_ sink: any LogSink) {
        runtime.addSink(sink)
    }

    /// Replace configuration at runtime.
    public static func setConfiguration(_ configuration: LogConfiguration) {
        runtime.setConfiguration(configuration)
    }

    /// Set a global sink error handler used by built-in sinks when bootstrapped.
    public static func setSinkErrorHandler(_ handler: LogSinkErrorHandler?) {
        runtime.setSinkErrorHandler(handler)
    }

    /// Create a sink error handler that records errors and forwards to the global handler.
    public static func makeSinkErrorHandler(label: String) -> LogSinkErrorHandler {
        runtime.makeSinkErrorHandler(label: label)
    }

    /// Snapshot of sink error counts and last errors.
    public static func sinkErrorSnapshots() -> [SinkErrorSnapshot] {
        runtime.sinkErrorSnapshots()
    }

    /// Clear all recorded sink errors.
    public static func clearSinkErrors() {
        runtime.clearSinkErrors()
    }

    /// Flush all sinks (best-effort).
    public static func flush() async {
        await runtime.flush()
    }

    /// Finish the stream and flush sinks (useful in command-line tools/tests).
    public static func shutdown() async {
        await runtime.shutdown()
    }

    /// Stream log events (redacted) for in-app viewers or debugging UIs.
    public static func events(
        bufferingPolicy: AsyncStream<LogEvent>.Continuation.BufferingPolicy = .bufferingOldest(256)
    ) -> AsyncStream<LogEvent> {
        runtime.makeEventStream(bufferingPolicy: bufferingPolicy)
    }

    /// Per-sink dropped counts (filters/rate limiting). Keys are sink identifiers.
    public static func sinkDroppedEventCounts() async -> [String: UInt64] {
        await runtime.sinkDroppedEventCounts()
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

    // MARK: - Runtime (private)

    private static let runtime = Runtime()

    private enum LogCommand: @unchecked Sendable {
        case event(LogEvent)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private struct SinkEntry {
        var id: String
        var sink: any LogSink
        var filter: LogFilter?
        var redactionKeys: Set<String>?
        var dropped: UInt64
    }

    private final class Runtime: @unchecked Sendable {
        private let lock = NSLock()

        private var configuration: LogConfiguration = .default
        private var manager: LogManager?
        private var continuation: AsyncStream<LogCommand>.Continuation?
        private var task: Task<Void, Never>?

        private var _dropped: UInt64 = 0
        private var defaultSubsystemOverride: String?
        private var sinkErrorHandler: LogSinkErrorHandler?
        private var sinkErrors: [String: SinkErrorState] = [:]

        var defaultSubsystem: String {
            lock.lock()
            let override = defaultSubsystemOverride
            lock.unlock()
            if let override, !override.isEmpty { return override }
            return Bundle.main.bundleIdentifier ?? "ModernSwiftLogger"
        }

        func setDefaultSubsystem(_ subsystem: String?) {
            lock.lock()
            if let subsystem, !subsystem.isEmpty {
                defaultSubsystemOverride = subsystem
            } else {
                defaultSubsystemOverride = nil
            }
            lock.unlock()
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

                let policy: AsyncStream<LogCommand>.Continuation.BufferingPolicy = .bufferingOldest(configuration.streamBufferCapacity)
                let stream = AsyncStream<LogCommand>(bufferingPolicy: policy) { cont in
                    self.continuation = cont
                }

                self.task = Task.detached(priority: .utility) { [mgr] in
                    for await command in stream {
                        switch command {
                        case .event(let event):
                            await mgr.process(event)
                        case .barrier(let cont):
                            await mgr.barrier()
                            cont.resume()
                        }
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

        func bootstrapIfNeeded() {
            ensureBootstrappedIfNeeded()
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

        func setSinkErrorHandler(_ handler: LogSinkErrorHandler?) {
            lock.lock()
            sinkErrorHandler = handler
            lock.unlock()
        }

        func getSinkErrorHandler() -> LogSinkErrorHandler? {
            lock.lock()
            defer { lock.unlock() }
            return sinkErrorHandler
        }

        func makeSinkErrorHandler(label: String) -> LogSinkErrorHandler {
            let safeLabel = label.isEmpty ? "Sink" : label
            return { [weak self] error in
                self?.recordSinkError(label: safeLabel, error: error)
            }
        }

        func sinkErrorSnapshots() -> [SinkErrorSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return sinkErrors.map { key, value in
                SinkErrorSnapshot(
                    sink: key,
                    count: value.count,
                    lastTimestamp: value.lastTimestamp,
                    lastError: value.lastError
                )
            }
        }

        func clearSinkErrors() {
            lock.lock()
            sinkErrors.removeAll(keepingCapacity: true)
            lock.unlock()
        }

        private func recordSinkError(label: String, error: Error) {
            lock.lock()
            var state = sinkErrors[label] ?? SinkErrorState()
            state.count &+= 1
            state.lastTimestamp = Date()
            state.lastError = String(describing: error)
            sinkErrors[label] = state
            let handler = sinkErrorHandler
            lock.unlock()

            handler?(error)
        }

        func shouldLog(level: LogLevel, category: String, tags: Set<LogTag>) -> Bool {
            lock.lock()
            let cfg = configuration
            lock.unlock()
            return cfg.allows(level: level, category: category, tags: tags)
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

            let result = cont.yield(.event(event))
            if case .enqueued = result {
                // ok
            } else {
                incrementDropped()
            }
        }

        func flush() async {
            ensureBootstrappedIfNeeded()
            guard let mgr = manager else { return }
            await enqueueBarrier()
            await mgr.flush()
        }

        func shutdown() async {
            let state = takeShutdownState()
            let cont = state.continuation
            let t = state.task
            let mgr = state.manager

            cont?.finish()
            _ = await t?.value
            await mgr?.finishTaps()
            await mgr?.flush()
        }

        func makeEventStream(
            bufferingPolicy: AsyncStream<LogEvent>.Continuation.BufferingPolicy
        ) -> AsyncStream<LogEvent> {
            ensureBootstrappedIfNeeded()
            let id = UUID()
            return AsyncStream(bufferingPolicy: bufferingPolicy) { cont in
                cont.onTermination = { _ in
                    Task.detached(priority: .utility) { [weak self] in
                        guard let mgr = self?.manager else { return }
                        await mgr.removeTap(id: id)
                    }
                }
                if let mgr = self.manager {
                    Task.detached(priority: .utility) {
                        await mgr.addTap(id: id, continuation: cont)
                    }
                } else {
                    cont.finish()
                }
            }
        }

        func sinkDroppedEventCounts() async -> [String: UInt64] {
            ensureBootstrappedIfNeeded()
            guard let mgr = manager else { return [:] }
            return await mgr.sinkDroppedCounts()
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
                sinks.append(StdoutSink(format: .text, configuration: cfg, onError: makeSinkErrorHandler(label: "StdoutSink")))
            }

            if sinks.isEmpty {
                sinks.append(StdoutSink(format: .text, configuration: cfg, onError: makeSinkErrorHandler(label: "StdoutSink")))
            }

            bootstrap(configuration: cfg, sinks: sinks)
        }

        private func incrementDropped() {
            lock.lock()
            _dropped &+= 1
            lock.unlock()
        }

        private func enqueueBarrier() async {
            guard let cont = continuation else { return }
            await withCheckedContinuation { barrier in
                Task.detached(priority: .utility) {
                    await Self.tryEnqueueBarrier(continuation: cont, barrier: barrier)
                }
            }
        }

        private static func tryEnqueueBarrier(
            continuation: AsyncStream<LogCommand>.Continuation,
            barrier: CheckedContinuation<Void, Never>
        ) async {
            while true {
                let result = continuation.yield(.barrier(barrier))
                switch result {
                case .enqueued:
                    return
                case .terminated:
                    barrier.resume()
                    return
                case .dropped:
                    await Task.yield()
                @unknown default:
                    barrier.resume()
                    return
                }
            }
        }

        private struct ShutdownState {
            let continuation: AsyncStream<LogCommand>.Continuation?
            let task: Task<Void, Never>?
            let manager: LogManager?
        }

        private struct SinkErrorState {
            var count: UInt64 = 0
            var lastTimestamp: Date? = nil
            var lastError: String? = nil
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
        private var sinks: [SinkEntry]
        private var taps: [UUID: AsyncStream<LogEvent>.Continuation] = [:]
        private var rateLimiter = RateLimiter()

        init(configuration: LogConfiguration, sinks: [any LogSink]) {
            self.configuration = configuration
            self.sinks = sinks.map { Self.makeEntry(for: $0) }
        }

        func reconfigure(configuration: LogConfiguration, sinks: [any LogSink]) {
            self.configuration = configuration
            self.sinks = sinks.map { Self.makeEntry(for: $0) }
            self.rateLimiter = RateLimiter()
        }

        func setConfiguration(_ configuration: LogConfiguration) {
            self.configuration = configuration
            self.rateLimiter = RateLimiter()
        }

        func addSink(_ sink: any LogSink) {
            sinks.append(Self.makeEntry(for: sink))
        }

        func process(_ event: LogEvent) async {
            // Filter again here in case config changed between call-site and processing.
            // (Also important if some code emits directly to the pipeline.)
            let tags = Set(event.tags.map { LogTag($0) })
            guard configuration.allows(level: event.level, category: event.category, tags: tags, applySampling: false) else {
                return
            }

            if !rateLimiter.allow(category: event.category, tags: tags, configuration: configuration) {
                incrementDroppedAll()
                return
            }

            let redactedBase = redact(event, keys: configuration.redactedMetadataKeys)
            emitToTaps(redactedBase)

            for index in sinks.indices {
                var entry = sinks[index]
                if let filter = entry.filter, !filter.allows(level: event.level, category: event.category, tags: tags) {
                    entry.dropped &+= 1
                    sinks[index] = entry
                    continue
                }
                let combinedKeys = configuration.redactedMetadataKeys.union(entry.redactionKeys ?? [])
                let sinkEvent: LogEvent
                if combinedKeys == configuration.redactedMetadataKeys {
                    sinkEvent = redactedBase
                } else {
                    sinkEvent = redact(event, keys: combinedKeys)
                }
                await entry.sink.emit(sinkEvent)
                sinks[index] = entry
            }
        }

        func flush() async {
            for entry in sinks {
                await entry.sink.flush()
            }
        }

        func barrier() async {
            // Acts as an ordering barrier in the stream consumer.
        }

        func addTap(id: UUID, continuation: AsyncStream<LogEvent>.Continuation) {
            taps[id] = continuation
        }

        func removeTap(id: UUID) {
            taps[id] = nil
        }

        func finishTaps() {
            for (_, cont) in taps {
                cont.finish()
            }
            taps.removeAll(keepingCapacity: true)
        }

        func sinkDroppedCounts() -> [String: UInt64] {
            var out: [String: UInt64] = [:]
            for entry in sinks {
                out[entry.id] = entry.dropped
            }
            return out
        }

        private func emitToTaps(_ event: LogEvent) {
            guard !taps.isEmpty else { return }
            var toRemove: [UUID] = []
            for (id, cont) in taps {
                let result = cont.yield(event)
                if case .terminated = result {
                    toRemove.append(id)
                }
            }
            for id in toRemove {
                taps[id] = nil
            }
        }

        private func incrementDroppedAll() {
            for index in sinks.indices {
                sinks[index].dropped &+= 1
            }
        }

        private func redact(_ event: LogEvent, keys: Set<String>) -> LogEvent {
            guard !keys.isEmpty, !event.metadata.isEmpty else { return event }
            let matcher = RedactionMatcher(keys: keys)
            var e = event
            for (k, v) in event.metadata {
                if matcher.matches(key: k, path: [k]) {
                    e.metadata[k] = .string("<redacted>")
                } else {
                    e.metadata[k] = v.redacted(using: matcher, path: [k])
                }
            }
            return e
        }

        nonisolated private static func makeEntry(for sink: any LogSink) -> SinkEntry {
            let id: String
            if let obj = sink as AnyObject? {
                id = "\(String(describing: type(of: obj)))-\(ObjectIdentifier(obj))"
            } else {
                id = "\(String(describing: type(of: sink)))-\(UUID().uuidString)"
            }
            return SinkEntry(id: id, sink: sink, filter: sink.filter, redactionKeys: sink.redactionKeys, dropped: 0)
        }

        private struct RateLimiter {
            private struct Bucket {
                var tokens: Double
                var lastRefill: TimeInterval
            }

            private var global: Bucket?
            private var perCategory: [String: Bucket] = [:]
            private var perTag: [String: Bucket] = [:]

            mutating func allow(category: String, tags: Set<LogTag>, configuration: LogConfiguration) -> Bool {
                if !configuration.tagRateLimits.isEmpty {
                    for tag in tags {
                        guard let limit = configuration.tagRateLimits[tag.rawValue] else { continue }
                        var bucket = perTag[tag.rawValue]
                        let allowed = allow(limit: limit, bucket: &bucket)
                        perTag[tag.rawValue] = bucket
                        if !allowed { return false }
                    }
                }

                if let limit = configuration.categoryRateLimits[category] {
                    var bucket = perCategory[category]
                    let allowed = allow(limit: limit, bucket: &bucket)
                    perCategory[category] = bucket
                    return allowed
                }
                if let limit = configuration.rateLimit {
                    var bucket = global
                    let allowed = allow(limit: limit, bucket: &bucket)
                    global = bucket
                    return allowed
                }
                return true
            }

            private mutating func allow(limit: RateLimit, bucket: inout Bucket?) -> Bool {
                let now = Date().timeIntervalSince1970
                var current = bucket ?? Bucket(tokens: Double(limit.burst), lastRefill: now)
                let elapsed = max(0, now - current.lastRefill)
                let refill = elapsed * Double(limit.eventsPerSecond)
                current.tokens = min(Double(limit.burst), current.tokens + refill)
                current.lastRefill = now

                if current.tokens >= 1 {
                    current.tokens -= 1
                    bucket = current
                    return true
                } else {
                    bucket = current
                    return false
                }
            }
        }
    }
}

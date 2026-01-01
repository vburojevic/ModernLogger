# ModernLogger

A modern, multi‑sink, structured logger for Apple platforms.

Highlights:
- Unified Logging (OSLog / Logger) integration
- Optional JSON Lines (JSONL) file sink with rotation + buffering
- Optional stdout sink for CI/tests/agents
- Feature/bug/marker tags for grep‑friendly debugging
- Task‑local context and scoped correlation IDs
- Per‑category min levels, sampling, and rate limiting
- Async event stream for in‑app log viewers
- Custom formatter support for text output

## Install (SwiftPM)

Add the package to your project and import:

```swift
import ModernLogger
```

## Quick start

```swift
// App startup
LogSystem.bootstrapFromEnvironment()

// Logger per area
let log = Log(category: "Networking")

// Log
log.info("Request started", metadata: ["url": .string(url.absoluteString)])
```

## Tags and markers

```swift
log.forFeature("Checkout").debug("step=validate")
log.forBug("JIRA-1234").warning("Unexpected server response")

log.marker("CHECKOUT_FLOW_ENTER")
```

## Task‑local context

```swift
let requestID = UUID().uuidString
await LogSystem.withContext(
    tags: [.feature("Search")],
    metadata: ["request_id": .string(requestID)]
) {
    log.info("Search started")
}
```

## Scopes and spans

```swift
let scope = log.scoped() // correlation_id + corr:<id> tag
scope.logger.info("step=begin")

let span = log.span("LoadUser")
// ... work
span.end()

let result = try log.measure("ParseJSON") {
    try parse()
}
```

## LogValue helpers

```swift
log.info("Payload",
         metadata: [
            "url": .url(url),
            "data": .data(payload, encoding: .base64),
            "error": .error(error),
            "user": .encodable(user)
         ])
```

## Sinks

- `OSLogSink`: default when available
- `StdoutSink`: text or JSON (useful for tests/CI)
- `FileSink`: JSONL with rotation + compression + buffering
- `InMemorySink`: ring buffer for tests and support workflows
- `TestSink`: awaitable helpers for tests

### Per‑sink filters

```swift
let config = LogConfiguration.default
let sinks: [any LogSink] = [
    OSLogSink(filter: LogFilter(minimumLevel: .info)),
    StdoutSink(format: .json, configuration: config, filter: LogFilter(minimumLevel: .debug))
]
LogSystem.bootstrap(configuration: config, sinks: sinks)
```

### Custom formatter

```swift
struct MyFormatter: LogFormatter {
    func format(_ event: LogEvent, configuration: LogConfiguration) -> String {
        "[\(event.level.name.uppercased())] \(event.message)"
    }
}

let sink = StdoutSink(format: .text, configuration: .default, formatter: MyFormatter())
```

## Event stream (in‑app viewers)

```swift
let stream = LogSystem.events()
Task {
    for await event in stream {
        print(event.message)
    }
}
```

## Configuration

### Per‑category minimum levels

```swift
var config = LogConfiguration.default
config.categoryMinimumLevels = ["Networking": .debug, "UI": .info]
```

### Sampling

```swift
var config = LogConfiguration.default
config.filter.sampling = .init(rate: 0.25) // 25% of events
```

### Rate limiting

```swift
var config = LogConfiguration.default
config.rateLimit = RateLimit(eventsPerSecond: 50) // global
config.categoryRateLimits = ["Networking": RateLimit(eventsPerSecond: 10)]
```

### Metadata merge policy

```swift
var config = LogConfiguration.default
config.metadataMergePolicy = .keepExisting // or .replaceWithNew
```

## File sink options

```swift
let rotation = FileSink.Rotation(
    maxBytes: 10 * 1024 * 1024,
    maxFiles: 5,
    maxAgeSeconds: 3600,
    compression: .zlib
)
let buffering = FileSink.Buffering(maxBytes: 64 * 1024, flushInterval: 2)
let sink = FileSink(url: FileSink.defaultURL(), rotation: rotation, buffering: buffering)
```

## Environment & Info.plist keys

All keys can be provided via environment variables or Info.plist entries:

```
MODERNLOGGER_MIN_LEVEL=debug
MODERNLOGGER_INCLUDE_TAGS=feature:Checkout,bug:JIRA-1234
MODERNLOGGER_STDOUT=1
MODERNLOGGER_STDOUT_FORMAT=json          # or "text"
MODERNLOGGER_STDOUT_MIN_LEVEL=info
MODERNLOGGER_OSLOG_MIN_LEVEL=notice
MODERNLOGGER_FILE=1                      # JSONL in caches dir
MODERNLOGGER_FILE_NAME=modernlogger.jsonl
MODERNLOGGER_FILE_MIN_LEVEL=debug
MODERNLOGGER_FILE_MAX_MB=10
MODERNLOGGER_FILE_MAX_FILES=5
MODERNLOGGER_FILE_MAX_AGE_SECONDS=3600
MODERNLOGGER_FILE_COMPRESSION=zlib       # none|zlib|lz4|lzfse|lzma
MODERNLOGGER_FILE_BUFFER_BYTES=65536
MODERNLOGGER_FILE_FLUSH_INTERVAL=2
MODERNLOGGER_REDACT_KEYS=password,token,authorization
MODERNLOGGER_CATEGORY_LEVELS=Networking=debug,UI=info
MODERNLOGGER_SAMPLE_RATE=0.25
MODERNLOGGER_RATE_LIMIT=50
MODERNLOGGER_CATEGORY_RATE_LIMITS=Networking=10
MODERNLOGGER_MERGE_POLICY=keepExisting   # or replaceWithNew
```

## JSONL event schema (file/stdout JSON)

Each line is a single JSON object matching `LogEvent`:

- `schemaVersion`, `id`, `timestamp`
- `level`, `subsystem`, `category`, `message`
- `tags`, `metadata`
- `source` (optional), `execution` (optional)

## Tests

```bash
swift test
```

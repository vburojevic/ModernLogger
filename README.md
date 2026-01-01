# ModernSwiftLogger

ModernSwiftLogger is a multi-sink, structured logger for Apple platforms. It keeps logs consistent across OSLog, JSONL files, and stdout while giving you first-class filtering, tags, rate limiting, and an in-app event stream.

## Highlights

- OSLog / Unified Logging integration with privacy control
- JSONL file sink with rotation, compression, and buffering
- Stdout sink for CI/tests/agents
- Structured metadata, tags, and markers for grep-friendly debugging
- Task-local context and scoped correlation IDs
- Per-category / per-tag minimum levels, sampling, and rate limits
- Async event stream for in-app log viewers

## Requirements

- Swift tools: 6.2
- Platforms: iOS 15+, macOS 12+, tvOS 15+, watchOS 8+, visionOS 1+

## Install (SwiftPM)

Add the package and import:

```swift
import ModernSwiftLogger
```

## Quick start

```swift
// App startup
LogSystem.bootstrapRecommended()

// Logger per area
let log = Log(category: "Networking")

// Log
log.info("Request started", metadata: ["url": .string(url.absoluteString)])
```

## Recommended setup (explicit sinks)

```swift
var config = LogConfiguration.recommended()
let sinks: [any LogSink] = [
    OSLogSink(privacy: config.oslogPrivacy)
]
LogSystem.bootstrap(configuration: config, sinks: sinks)
```

CI-friendly JSON stdout:

```swift
LogSystem.bootstrapRecommendedForCI()
```

## Core usage

### Tags and markers

```swift
log.forFeature("Checkout").debug("step=validate")
log.forBug("JIRA-1234").warning("Unexpected server response")

log.marker("CHECKOUT_FLOW_ENTER")
```

### Task-local context

```swift
let requestID = UUID().uuidString
await LogSystem.withContext(
    tags: [.feature("Search")],
    metadata: ["request_id": .string(requestID)]
) {
    log.info("Search started")
}
```

### Scopes and spans

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

### LogValue helpers

```swift
log.info("Payload",
         metadata: [
            "url": .url(url),
            "data": .data(payload, encoding: .base64),
            "summary": .stringTruncated(longText, maxBytes: 512),
            "error": .error(error, maxBytes: 512),
            "user": .encodable(user)
         ])
```

## Sinks

- `OSLogSink`: default on supported OSes
- `StdoutSink`: text or JSON (tests/CI/agents)
- `FileSink`: JSONL with rotation + compression + buffering
- `InMemorySink`: ring buffer for tests and support workflows
- `TestSink`: awaitable helpers for tests

Per-sink filters:

```swift
let config = LogConfiguration.default
let sinks: [any LogSink] = [
    OSLogSink(filter: LogFilter(minimumLevel: .info)),
    StdoutSink(format: .json, configuration: config, filter: LogFilter(minimumLevel: .debug))
]
LogSystem.bootstrap(configuration: config, sinks: sinks)
```

Custom formatter:

```swift
struct MyFormatter: LogFormatter {
    func format(_ event: LogEvent, configuration: LogConfiguration) -> String {
        "[\(event.level.name.uppercased())] \(event.message)"
    }
}

let sink = StdoutSink(format: .text, configuration: .default, formatter: MyFormatter())
```

## Configuration

### Default subsystem

```swift
LogSystem.setDefaultSubsystem("com.example.app")
```

### Per-category minimum levels

```swift
var config = LogConfiguration.default
config.categoryMinimumLevels = ["Networking": .debug, "UI": .info]
// or
config.setCategoryMinimumLevel(.debug, for: "Networking")
```

### Per-tag minimum levels

```swift
var config = LogConfiguration.default
config.tagMinimumLevels = ["feature:Checkout": .error]
// or
config.setTagMinimumLevel(.error, for: .feature("Checkout"))
```

### Sampling

```swift
var config = LogConfiguration.default
config.filter.sampling = .init(rate: 0.25) // 25% of events
```

### Rate limiting

```swift
var config = LogConfiguration.default
config.rateLimit = RateLimit(eventsPerSecond: 50)
config.categoryRateLimits = ["Networking": RateLimit(eventsPerSecond: 10)]
```

### Message truncation

```swift
var config = LogConfiguration.default
config.maxMessageBytes = 1024
```

### Redaction patterns

```swift
var config = LogConfiguration.default
config.redactedMetadataKeys = ["password", "auth.*", "*.token"]
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

File protection + backup exclusion:

```swift
let options = FileSink.FileOptions(
    protection: .completeUntilFirstUserAuthentication,
    excludeFromBackup: true
)
let sink = FileSink(url: FileSink.defaultURL(), fileOptions: options)
```

## Event stream (in-app viewers)

```swift
let stream = LogSystem.events()
Task {
    for await event in stream {
        print(event.message)
    }
}
```

## Privacy & PII

- Avoid logging secrets; redact aggressively.
- Use `LogPrivacy.private` for OSLog in production.
- Keep JSONL logs in Caches and exclude from backup when possible.

## Environment overrides (opt-in)

Overrides are applied only when you opt in:

```swift
var config = LogConfiguration.recommended()
config.applyOverrides([.environment()])
LogSystem.bootstrap(configuration: config, sinks: [OSLogSink()])
```

Available keys:

```
MODERNSWIFTLOGGER_MIN_LEVEL=debug
MODERNSWIFTLOGGER_INCLUDE_CATEGORIES=Networking,UI
MODERNSWIFTLOGGER_EXCLUDE_CATEGORIES=Spammy
MODERNSWIFTLOGGER_INCLUDE_TAGS=feature:Checkout,bug:JIRA-1234
MODERNSWIFTLOGGER_EXCLUDE_TAGS=trace
MODERNSWIFTLOGGER_OSLOG_PRIVACY=private       # or "public"
MODERNSWIFTLOGGER_SOURCE=1
MODERNSWIFTLOGGER_CONTEXT=1
MODERNSWIFTLOGGER_TEXT_STYLE=compact          # or "pretty"
MODERNSWIFTLOGGER_REDACT_KEYS=password,token,authorization
MODERNSWIFTLOGGER_BUFFER=1024
MODERNSWIFTLOGGER_CATEGORY_LEVELS=Networking=debug,UI=info
MODERNSWIFTLOGGER_TAG_LEVELS=feature:Checkout=error
MODERNSWIFTLOGGER_SAMPLE_RATE=0.25
MODERNSWIFTLOGGER_RATE_LIMIT=50
MODERNSWIFTLOGGER_CATEGORY_RATE_LIMITS=Networking=10
MODERNSWIFTLOGGER_TAG_RATE_LIMITS=feature:Checkout=5
MODERNSWIFTLOGGER_MERGE_POLICY=keepExisting   # or replaceWithNew
MODERNSWIFTLOGGER_MAX_MESSAGE_BYTES=1024
```

## For AI agents

ModernSwiftLogger is agent-friendly: it supports JSONL output and exposes a tiny CLI for discovery.

CLI:

```bash
swift run modernswiftlogger-cli --help
swift run modernswiftlogger-cli --sample
```

Recommended agent bootstrap (deterministic JSONL to stdout):

```swift
let config = LogConfiguration.recommended(minLevel: .debug)
let sink = StdoutSink(format: .json, configuration: config)
LogSystem.bootstrap(configuration: config, sinks: [sink])
```

If your agent can set environment variables, opt into overrides:

```swift
var config = LogConfiguration.recommended()
config.applyOverrides([.environment()])
LogSystem.bootstrap(configuration: config, sinks: [StdoutSink(format: .json, configuration: config)])
```

## JSONL event schema

Each line is a single JSON object matching `LogEvent`:

- `schemaVersion`, `id`, `timestamp`
- `level`, `subsystem`, `category`, `message`
- `tags`, `metadata`
- `source` (optional), `execution` (optional)

## Docs and examples

- DocC articles: Sinks, Filtering, Redaction, File Sink, Event Stream, In-app Viewer, Migration, Rotation/Compression, Production Checklist, Config Recipes, FAQ
- `Examples/SwiftUIDemo/README.md`

## Troubleshooting

- No logs? Ensure `LogSystem.bootstrap...()` is called before logging.
- Nothing in CI? Use `bootstrapRecommendedForCI()` or wire up a `StdoutSink`.
- Too noisy? Raise `minimumLevel` or add per-category / per-tag limits.

## Tests

```bash
swift test
```

## Changelog

See `CHANGELOG.md`.

## Contributing

See `CONTRIBUTING.md`.

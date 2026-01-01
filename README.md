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
LogSystem.bootstrapRecommended()

// Logger per area
let log = Log(category: "Networking")

// Log
log.info("Request started", metadata: ["url": .string(url.absoluteString)])
```

## Recommended defaults

```swift
var config = LogConfiguration.recommended()
LogSystem.bootstrap(configuration: config, sinks: [OSLogSink()])
```

Or:

```swift
LogSystem.bootstrapRecommended()
```

Or recommended + explicit environment / Info.plist overrides:

```swift
var config = LogConfiguration.recommended()
config.applyOverrides([.infoPlist(), .environment()])
LogSystem.bootstrap(configuration: config, sinks: [OSLogSink()])
```

Or CI-friendly JSON stdout:

```swift
LogSystem.bootstrapRecommendedForCI()
```

## Production checklist

- Use `.private` privacy for OSLog in release builds.
- Redact sensitive keys like `password`, `token`, `authorization`.
- Set `maxMessageBytes` to avoid oversized payloads.
- Use file protection + exclude logs from backup if needed.
- Use per‑category/tag levels and rate limits to reduce noise.

## Migration

If you're moving from `print` or `OSLog`, see the DocC article `Migration` for quick replacements and structured metadata examples.

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
            "summary": .stringTruncated(longText, maxBytes: 512),
            "error": .error(error, maxBytes: 512),
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

### Sink error handling

```swift
LogSystem.setSinkErrorHandler { error in
    print("ModernLogger sink error: \(error)")
}
```

### Sink error diagnostics

```swift
let snapshots = LogSystem.sinkErrorSnapshots()
LogSystem.clearSinkErrors()
```

If you build a custom sink, reuse the helper to record errors:

```swift
let handler = LogSystem.makeSinkErrorHandler(label: "MySink")
// Pass handler into your sink and call it on errors.
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

## Integration examples

### SwiftUI

```swift
struct ContentView: View {
    private let log = Log(category: "UI")

    var body: some View {
        Text("Hello")
            .task {
                log.info("ContentView appeared")
            }
    }
}
```

### In‑app log viewer

```swift
struct LogViewer: View {
    @State private var events: [LogEvent] = []

    var body: some View {
        List(events, id: \.id) { event in
            Text("[\(event.level.name.uppercased())] \(event.message)")
        }
        .task {
            let stream = LogSystem.events()
            for await event in stream {
                events.append(event)
                if events.count > 500 { events.removeFirst(events.count - 500) }
            }
        }
    }
}
```

### URLSession

```swift
let log = Log(category: "Networking")
let (data, _) = try await URLSession.shared.data(from: url)
log.debug("Response", metadata: ["bytes": .int(Int64(data.count))])
```

### Background task

```swift
let log = Log(category: "Background")
await LogSystem.withContext(tags: [.feature("Refresh")]) {
    log.notice("Background refresh started")
}
```

## Configuration

### Default subsystem

```swift
// Override the default subsystem used by new Log instances.
LogSystem.setDefaultSubsystem("com.example.app")
```

### Per‑category minimum levels

```swift
var config = LogConfiguration.default
config.categoryMinimumLevels = ["Networking": .debug, "UI": .info]
// or
config.setCategoryMinimumLevel(.debug, for: "Networking")
```

### Per‑tag minimum levels

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
config.rateLimit = RateLimit(eventsPerSecond: 50) // global
config.categoryRateLimits = ["Networking": RateLimit(eventsPerSecond: 10)]
// or
config.setCategoryRateLimit(RateLimit(eventsPerSecond: 10), for: "Networking")
```

### Per‑tag rate limiting

```swift
var config = LogConfiguration.default
config.tagRateLimits = ["feature:Checkout": RateLimit(eventsPerSecond: 5)]
// or
config.setTagRateLimit(RateLimit(eventsPerSecond: 5), for: .feature("Checkout"))
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

### File protection + backup exclusion

```swift
let options = FileSink.FileOptions(
    protection: .completeUntilFirstUserAuthentication,
    excludeFromBackup: true
)
let sink = FileSink(url: FileSink.defaultURL(), fileOptions: options)
```

## Privacy & PII guidance

- Avoid logging secrets (tokens, passwords, auth headers); redact aggressively.
- Prefer `LogPrivacy.private` for OSLog in production.
- Keep JSONL logs in Caches and exclude from backup if re‑downloadable.

## Environment & Info.plist overrides (opt-in)

Overrides are only applied when you opt in:

```swift
var config = LogConfiguration.recommended()
config.applyOverrides([.infoPlist(), .environment()])
LogSystem.bootstrap(configuration: config, sinks: [OSLogSink()])
```

Available keys via environment variables or Info.plist entries:

```
MODERNLOGGER_MIN_LEVEL=debug
MODERNLOGGER_INCLUDE_CATEGORIES=Networking,UI
MODERNLOGGER_EXCLUDE_CATEGORIES=Spammy
MODERNLOGGER_INCLUDE_TAGS=feature:Checkout,bug:JIRA-1234
MODERNLOGGER_EXCLUDE_TAGS=trace
MODERNLOGGER_OSLOG_PRIVACY=private       # or "public"
MODERNLOGGER_SOURCE=1
MODERNLOGGER_CONTEXT=1
MODERNLOGGER_TEXT_STYLE=compact          # or "pretty"
MODERNLOGGER_REDACT_KEYS=password,token,authorization
MODERNLOGGER_BUFFER=1024
MODERNLOGGER_CATEGORY_LEVELS=Networking=debug,UI=info
MODERNLOGGER_TAG_LEVELS=feature:Checkout=error
MODERNLOGGER_SAMPLE_RATE=0.25
MODERNLOGGER_RATE_LIMIT=50
MODERNLOGGER_CATEGORY_RATE_LIMITS=Networking=10
MODERNLOGGER_TAG_RATE_LIMITS=feature:Checkout=5
MODERNLOGGER_MERGE_POLICY=keepExisting   # or replaceWithNew
MODERNLOGGER_MAX_MESSAGE_BYTES=1024
```

Set the default subsystem in code with `LogSystem.setDefaultSubsystem(...)`, or pass a subsystem per `Log` instance.

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

## Changelog

See `CHANGELOG.md`.

## Contributing

See `CONTRIBUTING.md`.

## Examples

- `Examples/SwiftUIDemo/README.md`

## For AI agents (CLI + usage)

The package includes a tiny CLI for discovery:

```bash
swift run modernlogger-cli --help
swift run modernlogger-cli --sample
```

Use the CLI output to learn environment variables, and then bootstrap in code:

```swift
var config = LogConfiguration.recommended()
config.applyOverrides([.infoPlist(), .environment()])
LogSystem.bootstrap(configuration: config, sinks: [OSLogSink()])
```

## Support & troubleshooting

- No logs? Ensure you called `LogSystem.bootstrap...()` before logging.
- Nothing in CI? Use `bootstrapRecommendedForCI()` or enable `StdoutSink` explicitly (optionally with opt-in environment overrides).
- Too noisy? Raise `minimumLevel` and add per‑category/tag limits.

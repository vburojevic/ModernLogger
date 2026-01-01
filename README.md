# ModernLogger

A modern, multi‑sink, structured logger for Apple platforms.

Highlights:
- Unified Logging (OSLog / Logger) integration
- Optional JSON Lines (JSONL) file sink
- Optional stdout sink for CI/tests/agents
- Feature/bug/marker tags for grep‑friendly debugging
- Task‑local context (tags + metadata)

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

## Environment toggles

```
MODERNLOGGER_MIN_LEVEL=debug
MODERNLOGGER_INCLUDE_TAGS=feature:Checkout,bug:JIRA-1234
MODERNLOGGER_STDOUT=1
MODERNLOGGER_STDOUT_FORMAT=json   # or "text"
MODERNLOGGER_FILE=1               # JSONL in caches dir
MODERNLOGGER_FILE_NAME=modernlogger.jsonl
MODERNLOGGER_FILE_MAX_MB=10
MODERNLOGGER_REDACT_KEYS=password,token,authorization
```

## Sinks

- `OSLogSink`: default when available
- `StdoutSink`: text or JSON (useful for tests/CI)
- `FileSink`: JSONL with rotation
- `InMemorySink`: ring buffer for tests and support workflows

## Signposts (optional)

```swift
let log = Log(category: "DB")
await log.signpostInterval("LoadUser") {
    // work
}
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

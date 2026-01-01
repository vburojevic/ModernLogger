# ModernSwiftLogger

A modern, multi-sink, structured logger for Apple platforms.

## Getting Started

```swift
import ModernSwiftLogger

LogSystem.bootstrapRecommended()
let log = Log(category: "Networking")
log.info("Request started", metadata: ["url": .string(url.absoluteString)])
```

## AI agent tagging

Use feature and bug tags for traceable logs and debugging:

```swift
log.forFeature("Search").info("Query started")
log.forBug("JIRA-1234").error("Bad response")
log.marker("SEARCH_PIPELINE:fetch")
```

Reserved metadata:

Markers and spans include machine-parseable fields under `metadata["_msl"]`.

## Sinks

- OSLog (Unified Logging)
- Stdout (text or JSON)
- JSONL File (rotation + buffering)
- In-memory/Test sinks

## Articles

- <doc:Sinks>
- <doc:Filtering>
- <doc:Redaction>
- <doc:FileSink>
- <doc:EventStream>
- <doc:InAppViewer>
- <doc:Migration>
- <doc:RotationCompression>
- <doc:ProductionChecklist>
- <doc:ConfigurationRecipes>
- <doc:FAQ>

## Configuration

Use `LogConfiguration` for filtering, sampling, redaction, rate limiting, and formatting.

## Privacy

Avoid logging secrets. Use `LogPrivacy.private` in production and redaction patterns for metadata.

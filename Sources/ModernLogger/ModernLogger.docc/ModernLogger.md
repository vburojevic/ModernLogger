# ModernLogger

A modern, multi-sink, structured logger for Apple platforms.

## Getting Started

```swift
import ModernLogger

LogSystem.bootstrapRecommended()
let log = Log(category: "Networking")
log.info("Request started", metadata: ["url": .string(url.absoluteString)])
```

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

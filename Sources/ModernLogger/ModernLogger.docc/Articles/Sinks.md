# Sinks

ModernLogger supports multiple sinks to route events to different destinations.

## Built-in sinks

- `OSLogSink` for Unified Logging
- `StdoutSink` for CI/testing (text or JSON)
- `FileSink` for JSONL on disk
- `InMemorySink` for ring-buffer capture
- `TestSink` for awaitable tests

## Example

```swift
var config = LogConfiguration.default
let sinks: [any LogSink] = [
    OSLogSink(),
    StdoutSink(format: .text, configuration: config)
]
LogSystem.bootstrap(configuration: config, sinks: sinks)
```

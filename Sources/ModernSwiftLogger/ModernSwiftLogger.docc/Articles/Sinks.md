# Sinks

ModernSwiftLogger supports multiple sinks to route events to different destinations.

## Built-in sinks

- `OSLogSink` for Unified Logging
- `StdoutSink` for CI/testing (text or JSONL)
- `FileSink` for JSONL on disk
- `InMemorySink` for ring-buffer capture
- `TestSink` for awaitable tests

## Example

```swift
var config = LogConfiguration.default
config.deterministicJSON = true
let sinks: [any LogSink] = [
    OSLogSink(),
    StdoutSink(format: .json, configuration: config)
]
LogSystem.bootstrap(configuration: config, sinks: sinks)
```

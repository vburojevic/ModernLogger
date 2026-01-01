# Configuration Recipes

## Per-sink filters

```swift
let config = LogConfiguration.default
let sinks: [any LogSink] = [
    OSLogSink(filter: LogFilter(minimumLevel: .info)),
    StdoutSink(format: .json, configuration: config, filter: LogFilter(minimumLevel: .debug))
]
LogSystem.bootstrap(configuration: config, sinks: sinks)
```

## Stdout JSON for CI

```swift
var config = LogConfiguration.recommended()
config.deterministicJSON = true
let sink = StdoutSink(format: .json, configuration: config)
LogSystem.bootstrap(configuration: config, sinks: [sink])
```

## File sink with rotation

```swift
let rotation = FileSink.Rotation(maxBytes: 10 * 1024 * 1024, maxFiles: 5, compression: .zlib)
let sink = FileSink(url: FileSink.defaultURL(), rotation: rotation)
LogSystem.bootstrap(configuration: .default, sinks: [sink])
```

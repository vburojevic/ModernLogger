# Migration Guide

If you're moving from `print` or `OSLog` to ModernLogger, start here.

## From print

```swift
// Before
print("User loaded")

// After
let log = Log(category: "User")
log.info("User loaded")
```

## From OSLog

```swift
// Before
let logger = Logger(subsystem: "com.example", category: "Net")
logger.debug("Request started")

// After
let log = Log(subsystem: "com.example", category: "Net")
log.debug("Request started")
```

## Structured metadata

```swift
log.info("Response",
         metadata: ["status": .int(200), "bytes": .int(Int64(data.count))])
```

## Environment toggles (opt-in)

If you want runtime overrides, apply them explicitly:

```swift
var config = LogConfiguration.recommended()
config.applyOverrides([.environment()])
LogSystem.bootstrap(configuration: config, sinks: [StdoutSink(format: .json, configuration: config)])
```

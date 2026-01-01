# Redaction

Redact sensitive metadata before it reaches sinks.

```swift
var config = LogConfiguration.default
config.redactedMetadataKeys = ["password", "auth.*", "*.token"]
```

You can also apply sink-specific redaction keys when creating sinks.

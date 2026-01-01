# File Sink

`FileSink` writes JSONL to disk with rotation, buffering, and optional compression.

```swift
let rotation = FileSink.Rotation(
    maxBytes: 10 * 1024 * 1024,
    maxFiles: 5,
    maxAgeSeconds: 3600,
    compression: .zlib
)
let buffering = FileSink.Buffering(maxBytes: 64 * 1024, flushInterval: 2)
let options = FileSink.FileOptions(
    protection: .completeUntilFirstUserAuthentication,
    excludeFromBackup: true
)
let sink = FileSink(
    url: FileSink.defaultURL(),
    rotation: rotation,
    buffering: buffering,
    fileOptions: options,
    deterministicJSON: true
)
```

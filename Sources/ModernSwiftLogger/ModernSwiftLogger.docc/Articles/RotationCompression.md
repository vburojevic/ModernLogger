# Rotation and Compression

`FileSink` rotates files based on size and age, and can compress rotated logs.

```swift
let rotation = FileSink.Rotation(
    maxBytes: 256 * 1024,
    maxFiles: 3,
    maxAgeSeconds: 3600,
    compression: .zlib
)
let sink = FileSink(
    url: FileSink.defaultURL(),
    rotation: rotation
)
```

When rotation triggers, the old file is renamed with a timestamp and optionally compressed.

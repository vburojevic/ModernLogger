# Production Checklist

Use this checklist before shipping:

- Set `LogPrivacy.private` for OSLog in release builds.
- Redact sensitive metadata keys (`password`, `token`, `authorization`).
- Set `maxMessageBytes` to prevent oversized payloads.
- Use file protection and exclude JSONL logs from backup when appropriate.
- Use per‑category levels or tag levels to keep noise low.
- Enable rate limiting for noisy categories.

Example:

```swift
var config = LogConfiguration.recommended()
config.setCategoryMinimumLevel(.debug, for: "Networking")
config.setTagRateLimit(RateLimit(eventsPerSecond: 5), for: .feature("Checkout"))
```

# FAQ

## Why don't I see my logs?

- Check `minimumLevel` and per‑category/tag overrides.
- Ensure `LogSystem.bootstrap...()` is called before logging.
- In CI/tests, use `LogSystem.bootstrapRecommendedForCI()` or apply explicit environment overrides.

## How do I redact sensitive data?

Use `redactedMetadataKeys` with patterns like `auth.*` or `*.token`.

## How do I reduce noise in production?

Use per‑category or per‑tag minimum levels and rate limits.

## Where are JSONL files written?

`FileSink.defaultURL()` writes to Caches by default.

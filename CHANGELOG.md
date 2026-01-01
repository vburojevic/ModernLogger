# Changelog

## Unreleased

- Split sources into `LogTypes`, `LogSinks`, `LogSystem`, `Log` for clarity.
- Added recommended defaults + bootstrap helpers (including CI preset).
- Added redaction patterns, message truncation, sink error diagnostics.
- Added file rotation/compression tests + docs.
- Added DocC articles (Sinks, Filtering, Redaction, File Sink, Event Stream, In-app Viewer, Migration, Production Checklist, Config Recipes, FAQ).
- Added `modernswiftlogger-cli` for help and sample output.
- Removed implicit config and sink configuration from env/plist; only opt-in environment overrides remain via `LogConfiguration.OverrideSource`.

## Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **Major**: Breaking API changes.
- **Minor**: Backwards-compatible feature additions.
- **Patch**: Backwards-compatible bug fixes.

# BEADS

Tracks Oracle-suggested improvements for ModernSwiftLogger.

1. [x] Fix MERGE_POLICY env parsing (case-insensitive) + tests
2. [x] Support TEXT_STYLE alias (pretty -> verbose) + docs/CLI + tests
3. [x] Add machine-parseable marker/span metadata (reserved namespace) + tests
4. [x] Deterministic JSON option (stdout/file/CLI) + docs + tests
5. [x] Stdout sink testability (injectable writer) + tests
6. [x] FileSink apply file options to rotated/compressed files + tests
7. [x] Rotation filename collision-proofing + tests
8. [x] CLI upgrades: schema/env/tail/filter/stats/sample + docs
9. [x] Add tests for env include/exclude tags/categories
10. [x] Add tests for context merge semantics
11. [x] Add tests for event stream behavior
12. [x] Doc cleanup: remove duplicate LogScope doc comment, clarify JSON is JSONL
13. [x] LogSpan start/end location handling (include structured metadata)

import Foundation
import ModernLogger

private let usage = """
ModernLogger CLI
================

USAGE:
  modernlogger-cli [--help] [--sample]

DESCRIPTION:
  A tiny helper for AI agents and humans to discover ModernLogger.

OPTIONS:
  --help      Show this help text.
  --sample    Print a sample JSONL LogEvent to stdout.

QUICK START:
  1) swift run modernlogger-cli --help
  2) In your app: LogSystem.bootstrapRecommendedFromEnvironment()

ENVIRONMENT VARIABLES (prefix: MODERNLOGGER_):
  MIN_LEVEL, INCLUDE_TAGS, EXCLUDE_TAGS
  STDOUT, STDOUT_FORMAT, STDOUT_MIN_LEVEL
  OSLOG_MIN_LEVEL
  FILE, FILE_NAME, FILE_MIN_LEVEL, FILE_MAX_MB, FILE_MAX_FILES
  FILE_MAX_AGE_SECONDS, FILE_COMPRESSION, FILE_BUFFER_BYTES
  FILE_FLUSH_INTERVAL, FILE_PROTECTION, FILE_EXCLUDE_FROM_BACKUP
  REDACT_KEYS, CATEGORY_LEVELS, TAG_LEVELS
  SAMPLE_RATE, RATE_LIMIT, CATEGORY_RATE_LIMITS, TAG_RATE_LIMITS
  MERGE_POLICY, MAX_MESSAGE_BYTES, SUBSYSTEM
"""

private func printUsage() {
    print(usage)
}

private func printSample() {
    let event = LogEvent(
        level: .info,
        subsystem: "com.example.app",
        category: "Example",
        message: "Hello from ModernLogger CLI",
        tags: ["feature:Demo"],
        metadata: ["answer": .int(42), "ok": .bool(true)],
        source: nil,
        execution: nil
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.withoutEscapingSlashes]
    if let data = try? encoder.encode(event) {
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("{\"error\":\"failed to encode sample\"}")
    }
}

let args = Set(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") || args.contains("help") {
    printUsage()
    exit(0)
}

if args.contains("--sample") {
    printSample()
    exit(0)
}

printUsage()
exit(0)

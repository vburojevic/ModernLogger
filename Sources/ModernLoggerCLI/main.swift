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
  2) In your app: LogSystem.bootstrapRecommended()

CONFIGURATION SOURCES:
  Environment and Info.plist overrides are opt-in. Example:
    var config = LogConfiguration.recommended()
    config.applyOverrides([.infoPlist(), .environment()])
    LogSystem.bootstrap(configuration: config, sinks: [OSLogSink()])

ENVIRONMENT VARIABLES (prefix: MODERNLOGGER_):
  MIN_LEVEL, INCLUDE_CATEGORIES, EXCLUDE_CATEGORIES
  INCLUDE_TAGS, EXCLUDE_TAGS
  OSLOG_PRIVACY, SOURCE, CONTEXT, TEXT_STYLE
  REDACT_KEYS, BUFFER
  CATEGORY_LEVELS, TAG_LEVELS
  SAMPLE_RATE, RATE_LIMIT, CATEGORY_RATE_LIMITS, TAG_RATE_LIMITS
  MERGE_POLICY, MAX_MESSAGE_BYTES
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

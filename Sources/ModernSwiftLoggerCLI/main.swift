import ArgumentParser
import Foundation
import ModernSwiftLogger

@main
struct ModernSwiftLoggerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "CLI tools for ModernSwiftLogger logs and schemas.",
        discussion: """
        Tagging for agents:
          log.forFeature("Search").info("Query started")
          log.forBug("JIRA-1234").error("Bad response")
          log.marker("SEARCH_PIPELINE:fetch")
        """,
        subcommands: [Sample.self, Schema.self, Env.self, Tail.self, Filter.self, Stats.self],
        defaultSubcommand: nil
    )

    struct Sample: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a sample JSONL LogEvent.")

        @Option(help: "Kind: log | marker | span.")
        var kind: String = "log"

        func run() throws {
            let event = sampleEvent(kind: kind)
            let encoder = makeJSONEncoder(deterministic: true)
            let data = try encoder.encode(event)
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct Schema: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the LogEvent JSON schema.")

        func run() {
            print(logEventSchema)
        }
    }

    struct Env: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print supported environment variables.")

        func run() {
            print(envHelp)
        }
    }

    struct Tail: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the last N lines from a JSONL file.")

        @Argument(help: "Path to the JSONL log file.")
        var path: String

        @Option(name: .shortAndLong, help: "Number of lines to show.")
        var lines: Int = 200

        @Flag(help: "Keep following the file for new lines.")
        var follow: Bool = false

        func run() throws {
            let url = URL(fileURLWithPath: path)
            try tailFile(url: url, lines: lines, follow: follow)
        }
    }

    struct Filter: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Filter JSONL logs from a file or stdin.")

        @Option(help: "Path to a JSONL file (defaults to stdin).")
        var file: String?

        @Option(help: "Minimum level (trace|debug|info|notice|warning|error|critical).")
        var minLevel: String?

        @Option(help: "Category to match.")
        var category: String?

        @Option(help: "Exact tag to match (e.g., feature:Search).")
        var tag: String?

        @Option(help: "Feature name to match (converted to feature:<name>).")
        var feature: String?

        @Option(help: "Bug id to match (converted to bug:<id>).")
        var bug: String?

        @Option(help: "Marker name to match (converted to marker:<name>).")
        var marker: String?

        func run() throws {
            let lines = try readLines(file: file)
            let decoder = makeJSONDecoder()
            let min = minLevel.flatMap(LogLevel.init)

            let tagFilters = [tag,
                              feature.map { "feature:\($0)" },
                              bug.map { "bug:\($0)" },
                              marker.map { "marker:\($0)" }].compactMap { $0 }

            for line in lines {
                guard let event = try? decoder.decode(LogEvent.self, from: Data(line.utf8)) else { continue }
                if let min, event.level < min { continue }
                if let category, event.category != category { continue }
                if !tagFilters.isEmpty {
                    let tagSet = Set(event.tags)
                    if !tagFilters.allSatisfy({ tagSet.contains($0) }) { continue }
                }
                print(line)
            }
        }
    }

    struct Stats: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Summarize JSONL logs from a file or stdin.")

        @Option(help: "Path to a JSONL file (defaults to stdin).")
        var file: String?

        @Option(help: "Show top N tags.")
        var topTags: Int = 10

        func run() throws {
            let lines = try readLines(file: file)
            let decoder = makeJSONDecoder()

            var levelCounts: [String: Int] = [:]
            var categoryCounts: [String: Int] = [:]
            var tagCounts: [String: Int] = [:]

            for line in lines {
                guard let event = try? decoder.decode(LogEvent.self, from: Data(line.utf8)) else { continue }
                levelCounts[event.level.name, default: 0] += 1
                categoryCounts[event.category, default: 0] += 1
                for tag in event.tags {
                    tagCounts[tag, default: 0] += 1
                }
            }

            print("Levels:")
            for (k, v) in levelCounts.sorted(by: { $0.value > $1.value }) {
                print("  \(k): \(v)")
            }
            print("\nCategories:")
            for (k, v) in categoryCounts.sorted(by: { $0.value > $1.value }) {
                print("  \(k): \(v)")
            }
            if topTags > 0 {
                print("\nTop tags:")
                for (k, v) in tagCounts.sorted(by: { $0.value > $1.value }).prefix(topTags) {
                    print("  \(k): \(v)")
                }
            }
        }
    }
}

private func makeJSONEncoder(deterministic: Bool) -> JSONEncoder {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    if deterministic {
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    } else {
        enc.outputFormatting = [.withoutEscapingSlashes]
    }
    return enc
}

private func makeJSONDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return dec
}

private func readLines(file: String?) throws -> [String] {
    let handle: FileHandle
    if let file {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
    } else {
        handle = FileHandle.standardInput
    }
    let data = handle.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(whereSeparator: \.isNewline).map(String.init)
}

private func tailFile(url: URL, lines: Int, follow: Bool) throws {
    let data = try Data(contentsOf: url)
    let text = String(decoding: data, as: UTF8.self)
    let tail = text.split(whereSeparator: \.isNewline).suffix(max(0, lines))
    for line in tail {
        print(line)
    }

    guard follow else { return }
    let handle = try FileHandle(forReadingFrom: url)
    _ = try handle.seekToEnd()
    while true {
        if let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            if let out = String(data: chunk, encoding: .utf8) {
                print(out, terminator: "")
            }
        } else {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

private func sampleEvent(kind: String) -> LogEvent {
    let base = LogEvent(
        level: .info,
        subsystem: "com.example.app",
        category: "Example",
        message: "Hello from ModernSwiftLogger CLI",
        tags: ["feature:Demo"],
        metadata: ["answer": .int(42), "ok": .bool(true)],
        source: nil,
        execution: nil
    )
    switch kind.lowercased() {
    case "marker":
        var meta = base.metadata
        meta[LogReservedMetadata.key] = .object([
            LogReservedMetadata.kind: .string(LogReservedMetadata.kindMarker),
            LogReservedMetadata.name: .string("DEMO_MARKER")
        ])
        return LogEvent(
            level: .notice,
            subsystem: base.subsystem,
            category: base.category,
            message: "MARKER DEMO_MARKER",
            tags: base.tags + ["marker:DEMO_MARKER"],
            metadata: meta,
            source: base.source,
            execution: base.execution
        )
    case "span":
        let spanID = UUID().uuidString
        var meta = base.metadata
        meta["duration_ms"] = .double(12.5)
        meta[LogReservedMetadata.key] = .object([
            LogReservedMetadata.kind: .string(LogReservedMetadata.kindSpan),
            LogReservedMetadata.name: .string("DemoSpan"),
            LogReservedMetadata.phase: .string(LogReservedMetadata.phaseEnd),
            LogReservedMetadata.spanID: .string(spanID)
        ])
        return LogEvent(
            level: .info,
            subsystem: base.subsystem,
            category: base.category,
            message: "SPAN_END DemoSpan",
            tags: base.tags,
            metadata: meta,
            source: base.source,
            execution: base.execution
        )
    default:
        return base
    }
}

private let envHelp = """
ENVIRONMENT VARIABLES (prefix: MODERNSWIFTLOGGER_):
  MIN_LEVEL, INCLUDE_CATEGORIES, EXCLUDE_CATEGORIES
  INCLUDE_TAGS, EXCLUDE_TAGS
  OSLOG_PRIVACY, SOURCE, CONTEXT, TEXT_STYLE (compact|verbose, pretty alias)
  REDACT_KEYS, BUFFER
  CATEGORY_LEVELS, TAG_LEVELS
  SAMPLE_RATE, RATE_LIMIT, CATEGORY_RATE_LIMITS, TAG_RATE_LIMITS
  MERGE_POLICY (keepExisting|replaceWithNew)
  MAX_MESSAGE_BYTES, DETERMINISTIC_JSON
"""

private let logEventSchema = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ModernSwiftLogger LogEvent",
  "type": "object",
  "properties": {
    "schemaVersion": { "type": "integer" },
    "id": { "type": "string", "format": "uuid" },
    "timestamp": { "type": "string", "format": "date-time" },
    "uptimeNanoseconds": { "type": ["integer", "null"] },
    "level": { "type": "string" },
    "subsystem": { "type": "string" },
    "category": { "type": "string" },
    "message": { "type": "string" },
    "tags": { "type": "array", "items": { "type": "string" } },
    "metadata": { "type": "object" },
    "source": { "type": ["object", "null"] },
    "execution": { "type": ["object", "null"] }
  },
  "required": ["schemaVersion", "id", "timestamp", "level", "subsystem", "category", "message", "tags", "metadata"]
}
"""

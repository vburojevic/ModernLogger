# In-App Log Viewer

Use the event stream to build a lightweight in-app log viewer.

```swift
import SwiftUI
import ModernSwiftLogger

struct LogViewer: View {
    @State private var events: [LogEvent] = []

    var body: some View {
        List(events, id: \.id) { event in
            VStack(alignment: .leading, spacing: 4) {
                Text("[\(event.level.name.uppercased())] \(event.message)")
                    .font(.system(.body, design: .monospaced))
                if !event.tags.isEmpty {
                    Text(event.tags.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            let stream = LogSystem.events()
            for await event in stream {
                events.append(event)
                if events.count > 500 { events.removeFirst(events.count - 500) }
            }
        }
    }
}
```

Tip: consider redaction and privacy before displaying logs in production builds.

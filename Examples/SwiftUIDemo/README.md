# SwiftUI Demo

Minimal example for integrating ModernLogger in a SwiftUI app.

```swift
import SwiftUI
import ModernLogger

@main
struct DemoApp: App {
    init() {
        var config = LogConfiguration.recommended()
        config.applyOverrides([.infoPlist(), .environment()])
        LogSystem.bootstrap(configuration: config, sinks: [OSLogSink()])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    private let log = Log(category: "UI").taggedFeature("Demo")

    var body: some View {
        VStack {
            Button("Tap") {
                log.info("Tapped", metadata: ["screen": .string("home")])
            }
        }
        .task {
            log.notice("ContentView appeared")
        }
    }
}
```

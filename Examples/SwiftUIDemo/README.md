# SwiftUI Demo

Minimal example for integrating ModernLogger in a SwiftUI app.

```swift
import SwiftUI
import ModernLogger

@main
struct DemoApp: App {
    init() {
        LogSystem.bootstrapRecommendedFromEnvironment()
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

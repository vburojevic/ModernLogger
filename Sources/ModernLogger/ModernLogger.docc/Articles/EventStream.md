# Event Stream

Use `LogSystem.events()` to stream structured events for in-app viewers.

```swift
let stream = LogSystem.events()
Task {
    for await event in stream {
        print(event.message)
    }
}
```

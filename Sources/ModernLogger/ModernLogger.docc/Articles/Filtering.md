# Filtering

Use `LogFilter` and `LogConfiguration` to control what gets emitted.

## Minimum levels

```swift
var config = LogConfiguration.default
config.filter.minimumLevel = .info
config.categoryMinimumLevels = ["Networking": .debug]
config.tagMinimumLevels = ["feature:Checkout": .error]
```

## Sampling

```swift
var config = LogConfiguration.default
config.filter.sampling = .init(rate: 0.25)
```

## Rate limiting

```swift
var config = LogConfiguration.default
config.rateLimit = RateLimit(eventsPerSecond: 50)
config.categoryRateLimits = ["Networking": RateLimit(eventsPerSecond: 10)]
config.tagRateLimits = ["feature:Checkout": RateLimit(eventsPerSecond: 5)]
```

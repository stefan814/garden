# GardenKit

The Apple side of Garden: the same catalog and the same shared-or-download steps as [garden-android](../android/README.md).
Design and test results: [../DESIGN.md](../DESIGN.md).

## Use it

```yaml
# XcodeGen project.yml
packages:
  Garden: { path: ../../garden }        # or url: https://github.com/stefan814/garden
targets:
  MyApp:
    dependencies: [{ package: Garden, product: GardenKit }]
```

```swift
import GardenKit

// sharedContainer: nil when the app has no App Group (then everything is private to the app)
let garden = try Garden(appID: "com.example.app", sharedContainer: Garden.appGroupContainer("group.io.github.stefan814.garden"))
switch try garden.state("silero-vad-v5") {
case .ready: break
case .sharedAvailable: try garden.adopt("silero-vad-v5")               // no network
case .missing(let bytes, _): try await garden.download("silero-vad-v5", share: true) { done, total in }
}
let url = try garden.open("silero-vad-v5").url("vad.onnx")             // throws instead of handing over a partial file
```

## Tests

```bash
swift test        # catalog, two apps sharing one copy, resume/corrupt/mirror/cancel downloads
```

```bash
apple/harness/e2e.sh <simulator udid>   # two apps sharing one App Group, 23 checks (needs xcodegen)
```

The download tests run `android/tests/server.py` (needs `python3`) on a random port. The speech test needs macOS 26+
with the English speech model installed.

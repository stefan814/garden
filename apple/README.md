# GardenKit

The Apple side of Garden: the same catalog and the same three tiers as [garden-android](../android/README.md).
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

// 1. The phone's own model (iOS 26+): nothing for us to download
if #available(iOS 26, *), await SystemSpeech.status() != .unavailable {
    let phrases = try await SystemSpeech.transcribe(fileURL)       // [Phrase(text, start, end)] in seconds
}

// 2–3. Shared or downloaded files (sharedContainer: nil when the app has no App Group)
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
swift test        # catalog, two apps sharing one copy, resume/corrupt/mirror/cancel downloads, system speech
GARDEN_LONG_MINUTES=40 swift test --filter longRecording   # long-recording speed + memory check
```

```bash
apple/harness/e2e.sh <simulator udid>   # two apps sharing one App Group, 23 checks (needs xcodegen)
```

The download tests run `android/tests/server.py` (needs `python3`) on a random port. The speech test needs macOS 26+
with the English speech model installed.

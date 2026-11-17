# ModelLibraryKit

The iPhone (and Mac) side of the Model Library: the same model-list format and the same shared-or-download steps as [the Android version](../android/README.md).
Design and test results: [../DESIGN.md](../DESIGN.md).

## Use it

```yaml
# XcodeGen project.yml
packages:
  ModelLibrary: { path: ../model-library }   # a submodule of the app, or url: https://github.com/stefan814/model-library
targets:
  MyApp:
    dependencies: [{ package: ModelLibrary, product: ModelLibraryKit }]
```

```swift
import ModelLibraryKit

// sharedContainer: nil when the app has no App Group (then everything is private to the app)
// catalog: this app's own models, e.g. my-models.json in the app bundle (or Catalog(models:) in code). Any model works;
// files are shared by SHA-256, so other apps may call the same file anything.
let library = try ModelLibrary(appID: "com.example.app", sharedContainer: ModelLibrary.appGroupContainer("group.io.github.stefan814.garden"),
                        catalog: .bundled("my-models"))
switch try library.state("silero-vad-v5") {
case .ready: break
case .sharedAvailable: try library.adopt("silero-vad-v5")               // no network
case .missing(let bytes, _): try await library.download("silero-vad-v5", share: true) { done, total in }
}
let url = try library.open("silero-vad-v5").url("vad.onnx")             // throws instead of handing over a partial file
```

## Tests

```bash
swift test        # catalog, two apps sharing one copy, resume/corrupt/mirror/cancel downloads
```

```bash
apple/harness/e2e.sh <simulator udid>   # two apps sharing one App Group, 23 checks (needs xcodegen)
apple/harness/compat.sh <simulator udid> [old ref, default v1.0.0]   # an older version's app and this one share a copy, 11 checks
```

The download tests run `android/tests/server.py` (needs `python3`) on a random port. The speech test needs macOS 26+
with the English speech model installed.

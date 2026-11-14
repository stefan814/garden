# garden-android

Shared on-device models for Skald, Earshot and future apps. One copy of a model per phone, in Android's shared
store (BlobStoreManager), found by SHA-256. Design and test results: [../DESIGN.md](../DESIGN.md).

## Use it

```kotlin
// settings.gradle.kts of the app:  includeBuild("../../garden/android")   (or include the :garden module)
// app/build.gradle.kts:            implementation("io.github.stefan814:garden")   / implementation(project(":garden"))

val garden = Garden(context)                       // reads the bundled catalog (catalog/garden-catalog.json)
val id = "parakeet-tdt-110m-en-int8"

when (val s = garden.state(id)) {                  // all calls below are blocking: run them off the main thread
    is ModelState.Ready -> {}                                            // SHARED or PRIVATE: just open it
    is ModelState.SharedAvailable -> /* ask: "Use the shared model" */ garden.adopt(id)  // no network
    is ModelState.Missing -> /* ask: "Download (136 MB)" */ garden.download(id, share = true) { done, total -> }
}

garden.open(id).use { m ->                         // checks every file first; throws NotReady instead of crashing
    val rec = OfflineRecognizer(m.assets, OfflineRecognizerConfig(
        modelConfig = OfflineModelConfig(
            transducer = OfflineTransducerModelConfig(m.path("encoder.int8.onnx"), m.path("decoder.int8.onnx"), m.path("joiner.int8.onnx")),
            tokens = m.path("tokens.txt"), modelType = "nemo_transducer"), /* … */))
    // closing `m` after the engine is built is safe (tested), or keep it for the engine's lifetime
}
```

- **Moving existing files in without a download.** For Skald's old private copies or Earshot's APK assets, use
  `garden.contribute(id) { file -> inputStreamOrNull }`. Hashes are checked.
- **Letting go.** `garden.remove(id)` releases this app's hold. A copy other apps still use stays.
- **Model the phone already has.** `garden.system(capability)` reports one when you pass a `SystemProvider`. None
  ships yet, because ML Kit comes after its benchmark.
- **INTERNET permission.** The library doesn't declare it. An app that calls `download` declares it itself.

## Rules the tests taught us

- **Never pass an engine a raw path.** sherpa-onnx `abort()`s the whole app on a file it can't open, and Android
  blocks reopening shared files by path. Always use `open()` + `assets` + `path()`.
- **Every app that uses a shared file co-commits it.** `adopt`/`download`/`contribute` do this. Without it, a fresh
  install can't find the file once the first app is gone.
- **The catalog's ids, file names and hashes are frozen once published.** Add a new id instead of editing one.

## Tests

```bash
../scripts/fetch-deps.sh                     # sherpa-onnx AAR + test models (not in git; SHA-pinned)
./gradlew :garden:testDebugUnitTest          # catalog + naming rules (JVM)
tests/e2e.sh emulator-5580                   # 40 checks, two apps + fault-injecting server (emulator)
tests/real-downloads.sh emulator-5580        # every catalog model from its real url, then loaded
```

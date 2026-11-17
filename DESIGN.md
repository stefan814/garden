# Garden — shared on-device models for Skald, Earshot and future apps

Status (2026-11-16): two libraries, both working, for any model each app lists.
- **Android** (`android/`): 51 end-to-end checks pass on the emulator (40 also passed on a Pixel 10a before
  2026-11-16); every model in the harness's real list downloads and loads.
- **iPhone** (`apple/`, GardenKit): 13 tests pass on macOS; 22 two-app checks pass in the iOS Simulator. Not run on a
  real iPhone yet.

This repo holds Garden only. Each app (Skald, Earshot, …) adds Garden in its own repo; nothing app-specific lives
here.

## Goal

Garden shares models the phone doesn't have built in (Parakeet, Silero VAD, TitaNet, pyannote, …), so each is stored
once per phone however many of our apps use it. For a model in the catalog, Garden answers in this order:

1. **Shared** — another of our apps already put the exact file on the phone.
2. **Download** — the app fetches it, then contributes it to the shared store for the next app.

**Out of scope (decided 2026-11-14): models built into the phone** (Apple speech, Apple Intelligence / Foundation
Models, Gemini Nano, ML Kit). The OS already shares them, so each app calls them directly. Garden hands out readable
files only; engines (sherpa-onnx, LiteRT-LM, CoreML) stay in each app.

## What exists already (research, 2026-11-14)

- No ready-made cross-app model garden. Closest: [fgna/android-llm-service](https://github.com/fgna/android-llm-service)
  (LLM-only AIDL service, 0 stars, Android only).
- **Android has the shared store built in:** `BlobStoreManager` (API 30+), meant for "machine learning" data, keyed by SHA-256.
- **iOS has no cross-developer sharing.** App Groups only work between apps on the same team ID.
- Play for On-device AI packs are per app, and Google's policy bars sharing them.

## What's actually shared today

| File | Skald Android | Earshot Android | Size |
|---|---|---|---|
| Silero VAD `vad.onnx` (9e2449…) | download | in APK | 0.6 MB |
| TitaNet-small `embed.onnx` (ad4a18…) | download | in APK | 40 MB |
| Speech-to-text | Moonshine base (111 MB) | Parakeet TDT 110M int8 (~126 MB) | — |
| pyannote seg | download (6 MB) | — | — |
| Gemma 4 E2B | download (2.0–2.6 GB) | — | — |
| SoVITS voice pack | download (249 MB tar) | — | — |

**Today only about 41 MB matches byte for byte.** The real saving (~110–125 MB per phone) needs **one speech-to-text model
for both apps**. Earshot's call-audio benchmark: Parakeet 110M 3.5% WER vs Moonshine base 4.2% → Parakeet is the candidate.
Skald would need a re-check on table audio first (diarization of similar voices is its weak spot, and the ASR swap
changes timings).

## Android design

### Shared tier = BlobStoreManager

- **Handle identity is sha256 + label + tag + expiry.** If one character differs, you get a silent duplicate. Since
  2026-11-16 each app brings its own model list, so a handle depends on the file's bytes alone:
  - **Scheme 2** (any file): label `Garden shared model file`, tag `garden/v2/<sha256>`, expiry 0.
  - **Scheme 1** (the 21 files Garden's own catalog listed before then): label `Garden model <id> (<file>)`, tag
    `garden/v1/<id>/<file>`, from the id and name that catalog gave them, kept in the frozen table
    `android/garden/src/main/assets/garden-v1-handles.json` (keyed by hash; a unit test pins its SHA-256). Phones
    already hold these, and apps on older Garden versions look for them there, so they never move: no copying, and
    old and new apps keep sharing one copy.
  - Private copies (`files/garden/v1`) and the `garden.v1` preferences keep their names; their keys use the handle's tag.
- **Access: `allowPublicAccess()`.** These are public, SHA-pinned upstream models. Skald and Earshot use different signing
  keys, so `allowSameSignatureAccess` won't work. Google's docs say public
  access is "meant for publicly available data committed from libraries and SDKs".
- **Leases (verified in AOSP `BlobStoreConfig`).**
  - Each app can lease at most **max(300 MiB, 1% of storage)**. That's about 1.2 GB on a 128 GB phone.
  - When the last lease goes, the blob is deleted after a 6 h wait.
  - A committed blob nobody leases is cleaned up the same way.
  - Leases are checked with `getRemainingLeaseQuotaBytes()`. If quota runs out, the app falls back to its private storage.
- **Re-resolve on every load.** Users can clear shared data in Settings, so a blob seen yesterday may be gone today.
- **Gemma and other text models never go in BlobStore.** 2–2.6 GB is over any normal phone's lease quota, and an unleased
  blob would quietly vanish. Downloaded text models stay private to the app until a bigger shared store exists.

### The gate — PASSED 2026-11-14 (emulator, API 36, arm64, SELinux enforcing)

Spike: `spike/` (one app, two packages `…gardenspike.a` / `.b`; `spike/run.sh <serial> <a|b> <step>`).

| Route for app B to load app A's blob | Result |
|---|---|
| `/proc/self/fd/N` path | **denied** (EACCES). sherpa-onnx then **aborts the whole process**, which can't be caught |
| Real blob path `/data/system/blobstore/blobs/…` | denied |
| Copy into a memfd, then `/proc/self/fd/N` | **denied**. SELinux: `avc: denied { open } … appdomain_tmpfs`. Untrusted apps can't reopen *any* fd by path |
| **Serve the blob fd as an asset** (`AssetsProvider` + `ResourcesLoader`, API 30) → sherpa's `AssetManager` constructor | **works**. Nothing is reopened, and nothing is copied to disk |

Verified through the asset route:
- TitaNet voiceprint is **bit-identical** to loading a private copy.
- Silero VAD runs.
- **Parakeet 110M** (4 blobs, 136 MB) loads in 1.2 s and transcribed a test sentence exactly: "The goblin king opened the door
  and asked the party for three pieces of gold."
- **Access belongs to the committer, not the blob.** After the only committer was uninstalled, the blob stayed
  (B still leased it) and B could still read it. But a freshly installed app could **not see it**, because the public grant
  left with the committer. Fix, verified: **every app that uses a shared blob co-commits it** (same handle, streamed from
  its own `openBlob`, `allowPublicAccess`). `dumpsys blob_store` then shows one blob ID with two committers and still 6
  files on disk (no duplicate). After uninstalling and reinstalling A, all 6 were visible again.
- `commit()` checks the SHA-256 itself (result 0).
- The emulator quota is the 300 MiB floor. The full speech set (Parakeet + TitaNet + VAD ≈ 177 MB) fits even there.

Rules this sets for the library:
- **Use = co-commit + lease.** That's two system calls and one stream copy per file, once per app.
- "Not visible" is normal (e.g. you cleared shared data). The resolver falls back to download/choice and never crashes.
- **Never give sherpa a path it can't open.** It calls `abort()`. Always go through the asset route.
- The `AssetsProvider` gets asked for `assets/<path>`. Strip the prefix.
- Contribute by **streaming** from the source (asset or download). A 131 MB `readBytes()` hits the app's heap limit (OOM in the spike).

**Pixel 10a re-run — PASSED 2026-11-14 (Android 17 / API 37, 128 GB):**
- **Lease quota 1118 MiB per app.** The full speech set uses 169 MiB of it.
- Every result above repeated: `/proc` and real path denied, asset route works, identical voiceprint, VAD runs, Parakeet
  transcribes exactly, and co-commit keeps blobs visible after the contributor is uninstalled and reinstalled.
- **No cost vs. bundling** (3 alternating warm runs, Parakeet, 3.9 s clip):

  | Loaded from | Load | Decode | PSS added |
  |---|---|---|---|
  | Shared store (asset route) | 1.09–1.22 s | 97–118 ms | ~205 MB |
  | App's own APK (Earshot today) | 1.10–1.24 s | 98–117 ms | ~205 MB |

  The first-ever load was slower (4.1 s load / 1.6 s decode). That's a cold start, not the route: the APK run right after had a
  cold first run as well.
- **Google's own apps use BlobStore on this phone** (Google app, Android System Intelligence, Wallet: 35 blobs), so it's a
  well-used production mechanism.
- Cleanup: test apps uninstalled after releasing leases, and 0 `garden` blobs remain.

### Library shape (`garden-android`, plain Kotlin/Android library)

```kotlin
sealed interface Resolution {      // early sketch; the built library's API is in android/README.md
  data class Shared(val assets: AssetManager, val paths: Map<String, String>) : Resolution // blob fds served as assets (spike-proven), already leased
  data class Download(val files: List<CatalogFile>, val bytes: Long) : Resolution
}
Garden.resolve(capability: Capability, prefs: Prefs): Resolution
Garden.contribute(file: CatalogFile, source: File)   // after an in-app download or from APK assets
Garden.release(modelId)                               // app no longer needs it
```

- Brought in as a Gradle composite build (`includeBuild("../garden/android")`) or a submodule.

## iOS design (`GardenKit`, Swift package) — BUILT 2026-11-14

`Package.swift` at the repo root, sources in `apple/`. Each app passes its own model list, as on Android. Files were
always stored by hash here, so nothing else changed.

- **Shared tier: an optional App Group container.**
  - Files live at `Garden/blobs/<sha256>`. Each app that uses one leaves a marker at `Garden/users/<sha256>/<appID>`.
  - A file is deleted when its last marker goes. `flock` on `Garden/.lock` serialises adopt, place and remove.
  - `sharedContainer: nil` means private only. That's the default, because App Groups need the same team and it's
    still unverified whether a free personal team gets them.
  - **Known gap:** iOS can't tell us another app was deleted, so a deleted app's marker keeps the file until the user
    removes the model in the remaining apps. `holders(id)` lists the markers for a settings screen.
- **Two-app test in the Simulator (`apple/harness/e2e.sh`, 23 checks, PASSED 2026-11-14 on an iOS 27.2 Simulator):**
  - Setup: apps A and B share `group.io.github.stefan814.garden`. App C has no App Group.
  - One download, two apps: B adopts A's copy with no network and reads every byte. C gets no group container, so
    the Simulator does enforce the entitlement.
  - The file stays until its last holder lets go. Private copies stay private. A cut download resumes with Range,
    and corrupt bytes are refused.
  - Uninstalling A leaves B reading. A reinstalled A finds its old marker, which is the stale-marker case.
  - Once every group app is uninstalled, iOS deletes the group container.
  - Not covered: real-device signing. Whether a free personal team may use App Groups is still unknown.
- **Private tier:** `Application Support/Garden`, excluded from backup.
- **Download tier:**
  - Resumable `Range` download over URLSession; tries every url, a few rounds, SHA-checked.
  - A `200` reply to a Range request restarts the file. A `206` must start at our offset.
  - Cancelling keeps the partial file.
  - Same API as Android: `state` / `adopt` / `download(share:)` / `contribute` / `remove` / `open`.
- **Running a downloaded model is the app's job.** GardenKit hands out file URLs. An app that wants Parakeet on iPhone
  brings its own engine: sherpa-onnx publishes a prebuilt iOS xcframework, v1.13.4, on its `xcframework` release tag.

## Earshot models — DECIDED 2026-11-14: one app, you choose

**One Earshot build.** No Full/Lite split, and no speech models bundled in the APK. On first run (and in Settings), Earshot
offers **Use the shared model** when Garden finds one, and **Download in Earshot** either way. Which one is up to you.
- Downloading needs the INTERNET permission. It's used only for that user-started, SHA-pinned model download. Nothing is
  uploaded, and the privacy note in the app must say exactly that.
- If you choose neither, there's no transcription. Say so plainly.
- If the shared model disappears (you cleared shared data, or the other app released it), Earshot falls back to the same choice.

## Deferred: cross-app text-model sharing

No current app needs a big text model in two places (Earshot uses none). Revisit if a second app wants Gemma. The
likely shape is a small companion "Garden" app that owns the file and hands out read-only descriptors through a
`ContentProvider`. The same fd/SELinux test applies.

## Build order

1. ✅ `catalog/garden-catalog.json` (moved into the apps on 2026-11-16, see step 5): Parakeet 110M, Silero VAD, TitaNet-small, pyannote seg 3.0. Every hash matches what
   the apps pin today. Parakeet's per-file source is a third-party Hugging Face mirror (punitd, pinned commit), since
   k2-fsa only ships it as a tar.bz2. The SHA check guarantees the bytes, but not that the mirror stays up. Each file
   takes several `urls` (tested), so a self-hosted copy can be added as a second source.
2. ✅ `garden-android` (`android/garden`), see `android/README.md`. API: `state` → `adopt` / `download(share)` /
   `contribute` → `open` (AssetManager + paths) → `remove`.
   - Handle scheme frozen: tag `garden/v1/<id>/<file>`, label `Garden model <id> (<file>)`, expiry 0, public access.
   - The library manifest declares no INTERNET permission.
   - Tests:
     - 7 JVM unit tests.
     - **40 end-to-end checks** (`android/tests/e2e.sh`, two-package harness + fault-injecting server) covering:
       cross-app adopt, a Service context, closing the OpenModel early, reinstall visibility, dropped-connection
       resume, a server that ignores Range, system and private SHA rejection, dead-mirror fallback, a paused download
       resumed in a later call, adopt-instead-of-download with zero network, a model **split** across shared and private
       storage (Ready, and it opens), and **no descriptor leak** over 30 open/load/close cycles (122 → 122 fds).
     - Every real catalog url downloaded and loaded (`tests/real-downloads.sh`; Parakeet 23 s on the emulator).
     - **Pixel 10a (API 37): all 40 checks pass** (test server via `adb reverse`, 141 → 141 fds), and every real url
       downloads and loads over the phone's own connection (Parakeet 51 s). The phone was left clean: no test apps, no
       Garden blobs, no reverse rule.
   - **Found by the tests:** `BlobStoreManager.Session.getSize()` reports the whole preallocated length once
     `openWrite()` is called, so it can't serve as a resume point. Garden keeps its own byte count.
   - **Also found by review:** `state()` missed split models (fixed). Real catalogs may not list one file in two
     models, because private copies are stored by hash.
3. ✅ `GardenKit` (`apple/`), see `apple/README.md`. Same catalog and the same API as Android. Two-app Simulator test:
   `apple/harness/e2e.sh`.
4. Adding Garden to each app happens in that app's repo, not here: Skald Android and iPhone, Earshot Android and
   iPhone.
5. ✅ **Model-agnostic (2026-11-16).** Garden no longer ships a model list: `Garden(context, catalog)` /
   `Garden(appID:sharedContainer:catalog:)` take the app's own, and the old list moved into the apps (Earshot's
   `catalog/earshot-models.json`; the Android harness's `real-catalog.json`). Android handles are named by hash
   (scheme 2), with the frozen scheme-1 table for files already on phones. Tests: 9 JVM + 51 emulator checks (new: one
   app's own name for Parakeet's vocabulary finds the shared copy, and two apps calling a new file different things get
   one `garden/v2/<sha>` blob and no second download), 13 Swift tests + 22 Simulator checks. Upgrading Earshot in place
   on the emulator and Simulator kept Cantonese ready with no download, and it still transcribes. Skald stays on its
   pinned Garden until its submodule is bumped. Its files keep their v1 handles (its leases on the emulator were
   unchanged), so it should keep sharing with Earshot; that pairing wasn't run after the change.
5. Not done: a real-iPhone run, including whether a free personal team may use App Groups.

## Decisions (2026-11-14)

1. **One speech-to-text model for both apps: yes.** Parakeet TDT 110M int8. Skald switches from Moonshine base, after a
   WER re-check on table audio (TAZ Ep.1).
2. **Earshot:** one app. You pick "shared" or "download in app" (see above).
3. **Speech-to-text first.** Text models (Gemma etc.) come later, outside BlobStore, which is too small (see Deferred).

# Garden

Shared on-device models for our phone apps. Each model is stored once per phone, however many apps use it.

Garden is for models the phone doesn't have built in, like Parakeet speech-to-text. An app asks Garden for one and
gets it from the first place that has it:

1. **The shared store.** Another of our apps already downloaded the exact file (found by SHA-256), so this app uses that
   copy with no network.
2. **A download.** The app fetches it, checks it, and puts it in the shared store for the next app. The user can keep it
   private to the app instead.

Built-in models (Apple speech, Apple Intelligence, Gemini Nano and so on) are not part of Garden. The phone already
shares those, and each app calls them directly.

| | Android | iPhone |
|---|---|---|
| Library | [`android/`](android/README.md) (Kotlin) | [`apple/`](apple/README.md) (GardenKit, Swift package) |
| Shared store | Android's BlobStoreManager (API 30+) | An App Group container (apps on the same team) |
| Tests | 40 two-app checks on emulator + Pixel 10a | 12 unit tests + 23 two-app checks in the Simulator |

Both read the same model list, [`catalog/garden-catalog.json`](catalog/garden-catalog.json). Its ids, file names and
hashes never change once published.

Apps add Garden in their own repos. This repo only holds Garden. Design notes and test results:
[DESIGN.md](DESIGN.md).

License: Apache-2.0. The models keep their own licenses (see [NOTICE](NOTICE)).

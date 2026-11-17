# Garden

Shared on-device models for our phone apps. Each model is stored once per phone, however many apps use it.

Garden works with any model file: each app brings its own list of models, and a file is shared with every app that
lists the same bytes (same SHA-256), whatever each app calls it. It's for models the phone doesn't have built in, like
Parakeet speech-to-text. An app asks Garden for one and
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
| Tests | 9 unit tests + 51 two-app checks on the emulator | 13 unit tests + 22 two-app checks in the Simulator |

Each app passes its own model list (a JSON file in the app, or built in code). Two apps never have to agree on ids
or file names: Garden shares by hash alone. On Android every app must still name a shared file exactly the same way
for the system, so that name comes from the hash; files Garden shared before apps brought their own lists keep their
old names, from a frozen table in the library ([DESIGN.md](DESIGN.md#android-design)).

Apps add Garden in their own repos. This repo only holds Garden. Design notes and test results:
[DESIGN.md](DESIGN.md).

License: Apache-2.0. The models keep their own licenses (see [NOTICE](NOTICE)).

# Model Library

Shared on-device models for our phone apps. Each model is stored once per phone, however many apps use it.

The Model Library works with any model file: each app brings its own list of models, and a file is shared with every app that
lists the same bytes (same SHA-256), whatever each app calls it. It's for models the phone doesn't have built in, like
Parakeet speech-to-text. An app asks the Model Library for one and
gets it from the first place that has it:

1. **The shared store.** Another of our apps already downloaded the exact file (found by SHA-256), so this app uses that
   copy with no network.
2. **A download.** The app fetches it, checks it, and puts it in the shared store for the next app. The user can keep it
   private to the app instead.

Built-in models (Apple speech, Apple Intelligence, Gemini Nano and so on) are not part of the Model Library. The phone already
shares those, and each app calls them directly.

| | Android | iPhone |
|---|---|---|
| Library | [`android/`](android/README.md) (Kotlin) | [`apple/`](apple/README.md) (ModelLibraryKit, Swift package) |
| Shared store | Android's BlobStoreManager (API 30+) | An App Group container (apps on the same team) |
| Tests | 9 unit tests + 51 two-app checks on the emulator | 13 unit tests + 22 two-app checks in the Simulator |

Each app passes its own model list (a JSON file in the app, or built in code). Two apps never have to agree on ids
or file names: the Model Library shares by hash alone. On Android every app must still name a shared file exactly the same way
for the system, so that name comes from the hash; files the Model Library shared before apps brought their own lists keep their
old names, from a frozen table in the library ([DESIGN.md](DESIGN.md#android-design)).

**Versions.** Each app pins its own Model Library version (Earshot and Skald use a git submodule at a tagged commit), so
the Model Library can change without touching any app; an app takes a new version only when it moves its pin. Two promises make
that safe:

- **The on-device format never breaks.** Apps on different Model Library versions share the same copies on one phone: the
  Android handle naming (including the frozen v1 table) and the iPhone App Group layout (`Garden/blobs/<sha256>`,
  `Garden/users/<sha256>/<appID>`) only ever grow. `android/tests/compat.sh` and `apple/harness/compat.sh` run an app on an older
  Model Library against one on this version, both ways.
- **The API follows semantic versioning** (tags `vMAJOR.MINOR.PATCH`). Only a new major version changes what an app
  calls; each app keeps those calls in one file (Earshot: `ModelStore`).

**Renamed from Garden (v2.0.0).** The code names changed: Android `io.github.stefan814.modellibrary.ModelLibrary`
(module `:modellibrary`), iPhone `ModelLibraryKit` / `ModelLibrary`. Names saved on phones did not change, so v1 and
v2 apps keep sharing the same copies: the Android shared-file names (`garden/v1/…`, `garden/v2/…`, and labels like
"Garden shared model file", which Android Settings shows), the `garden.v1` private storage, and the iPhone `Garden/`
folders. Apps on a v1 pin keep working; moving the pin to v2 means updating those names in the app.

Apps add the Model Library in their own repos. This repo only holds the Model Library. Design notes and test results:
[DESIGN.md](DESIGN.md).

License: Apache-2.0. The models keep their own licenses (see [NOTICE](NOTICE)).

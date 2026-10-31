# Updates

uiui updates itself from GitHub Releases on a public repository (`UIUIUpdateRepository` in `resources/Info.plist`, currently `ravishar313/uiui`). The app and its speech models are released separately, so an app update never re-downloads models.

## Cutting an app release

1. Bump `CFBundleShortVersionString` (dotted numbers, for example `1.2.0`) and `CFBundleVersion` in `resources/Info.plist`.
2. Run `scripts/package-release.sh`. It builds an app-only bundle (`build-app.sh --without-models`, about 14 MB), zips it as `build/release-<version>/uiui-<version>-arm64.zip`, writes `<zip>.sha256`, and checks the zip extracts to a bundle with a valid signature. Without `--publish` it only prints what it would upload.
3. Publish: `scripts/package-release.sh --publish --notes notes.md` creates release `v<version>` with both files. It refuses to publish if a model pack the build needs is not yet released.

The full app with bundled models (for a DMG or a first install) is still `scripts/build-app.sh`.

## Model packs

`resources/ModelPacks.json` lists the packs one build needs: name, id, archive name, SHA-256 and size. The id is the first 12 hex characters of the SHA-256 of the pack's manifest (`assets.json` for Phonon, `manifest.json` for MiniLM). `build-app.sh` copies the file into the app, where the code signature seals it, and refuses to build if an id no longer matches `resources/Phonon` or `resources/MiniLM`.

- Packs install once to `~/Library/Application Support/uiui/Models/<Name>-<id>/`. At runtime the app uses its bundled copy if the manifest id matches, otherwise the stored copy.
- `scripts/package-models.sh` builds `build/model-packs/uiui-model-<name>-<id>.aar`, an LZMA Apple Archive (byte-stable for the same files; unpacked by the app with macOS's `/usr/bin/aa`) and rewrites `ModelPacks.json`. With `--publish` it creates one release per pack that is not yet published, tagged `models-<name>-<id>`, in the same repository. Publish packs before the app release that needs them.
- A pack changes only when the model changes. A new model gives a new id and a new tag; the old tag stays, and installed apps keep their pack until they update to the app that needs the new one. After an app needs a new pack, older stored packs are removed.
- Commit the updated `ModelPacks.json` together with the model change.

## What the app verifies

The app checks once at launch (at most every 24 hours, if automatic checks are on) and when the user chooses Check for Updates. It makes one request to `https://api.github.com/repos/<repo>/releases/latest`; there is no polling. For an install it:

1. Accepts only a published, non-prerelease release with `uiui-<version>-arm64.zip` and `.sha256`, served over https from github.com, objects.githubusercontent.com or release-assets.githubusercontent.com.
2. Checks the zip against the SHA-256 file, then unpacks it and requires exactly one `uiui.app` with bundle id `app.uiui.mac`, the release version, and a version newer than the running one.
3. Requires the new bundle to satisfy the running app's designated requirement (same certificate and identifier). Privacy grants (Microphone, Accessibility) therefore carry over, and a tampered download is rejected.
4. Reads the new bundle's `ModelPacks.json` and, before replacing anything, makes sure each pack is stored: copied from the running app when its id matches (so updating from a full bundle copies models locally and downloads nothing), otherwise downloaded and checked against the signed archive SHA-256 and the pack's own manifest verification.
5. Swaps the bundle (restoring the old one on failure) and relaunches. Any failure leaves the current app intact and shows a short reason.

If uiui runs from a disk image, a translocated path or a read-only location, it asks the user to drag it into Applications first.

## Signing certificate

The persistent self-signed certificate (`docs/local-signing.md`) must never change. The update check requires the new app to match the running app's certificate, so a different certificate makes every update fail and makes macOS drop all privacy grants. It expires 23 October 2027; plan the replacement before then, and expect a one-time manual reinstall and re-grant for everyone when it happens.

## Notes

- The repository must be public so downloads work without authentication.
- A build without the updater cannot update itself: install the first updater build manually once. If that build is app-only it fetches models from Settings with Prepare Speech.

## Sizes and disk images

The quantized Phonon weights are already near their information limit (uniform 6-bit palette codes and a balanced 1-bit sparsity mask), so no repacking of the weights helps; LZMA only shrinks the remaining parts. Measured on 26 Oct 2026:

| Artifact | zip | LZMA |
|---|---|---|
| Phonon pack | 270.8 MB | 219.9 MB |
| MiniLM pack | 28.2 MB | 27.7 MB |
| App-only update | 13.8 MB | — |

`scripts/package-dmg.sh` builds `build/dmg-<version>-lite/uiui-<version>-lite.dmg` (10.7 MB, no models; setup downloads the packs once) and, with `--full`, a 265 MB image that includes the models for an offline install (ULMO compression). A lite install needs the model packs to be published. Making the weights themselves smaller would mean re-quantizing Phonon (for example fewer palette bits), which changes accuracy and needs a new benchmark before shipping.

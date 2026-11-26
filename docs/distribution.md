# Building the macOS distribution

Build on Apple Silicon with Xcode, SwiftPM, Rust and a **Developer ID Application** signing identity available to codesign. The release build uses hardened runtime and a secure timestamp for the encoder and app. Set GIF_MACHINE_SIGN_IDENTITY to choose among multiple identities.

```sh
scripts/build-gifski.sh
swift test
scripts/build-dmg.sh
scripts/package-gifski-source.sh
```

The disk image and the corresponding encoder source are in .build/distribution. Mount the image read-only and install the app on a clean Mac. Check first launch, Screen Recording permission, MP4 and GIF delivery, a smaller copy, and the lifetime of a copied clip with saving turned off.

## Notarization and checksums

Submit the signed image to Apple using a previously configured notarytool keychain profile. This requires access to the signing team’s account.

```sh
image=.build/distribution/Capture-Machine-1.0.1-arm64.dmg
xcrun notarytool submit "$image" --keychain-profile "$NOTARY_PROFILE" --wait
```

After Apple returns **Accepted**, run the following on those same bytes:

```sh
scripts/finalize-dmg.sh "$image"
(cd .build/distribution && shasum -a 256 -c SHA256SUMS)
```

The script staples the ticket, checks Gatekeeper and the disk image, and writes the cask and SHA256SUMS against the stapled image. Rebuilding or re-signing produces a different artifact.

## Release assets

The v1.0.1 release uses the signed, stapled Capture-Machine-1.0.1-arm64.dmg, gifski-1.34.0-source.tar.gz and SHA256SUMS. The encoder archive includes its Cargo.lock, vendored dependencies and offline build instructions. Keep it available alongside the disk image. The Casks/capture-machine.rb checksum and the product page download must resolve to this release. Check a fresh download on a clean Mac before announcing it.

The installer copies Resources/InstallerLayout into the disk image as Finder’s .DS_Store. It places Capture Machine on the left and Applications on the right in icon view. The volume title tells the user to drag the app to Applications. The layout is static metadata, so building a release does not require opening Finder. [DS_Store format and editing](https://ds-store.readthedocs.io/en/latest/)

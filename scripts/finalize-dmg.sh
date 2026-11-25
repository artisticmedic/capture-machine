#!/bin/sh
# Run only after Apple accepts the disk image. Stapling changes its checksum.
set -eu
cd "$(dirname "$0")/.."
image=${1:?Usage: scripts/finalize-dmg.sh .build/distribution/Capture-Machine-VERSION-arm64.dmg}
test -f "$image"
xcrun stapler staple "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature "$image"
hdiutil verify "$image" > /dev/null
scripts/release-checksums.sh "$image"

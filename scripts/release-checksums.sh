#!/bin/sh
# Generate checksums and the local cask for the exact image on disk. Run again after stapling.
set -eu
cd "$(dirname "$0")/.."
image=${1:?Pass the release disk image}
test -f "$image"
name=$(basename "$image")
version=$(expr "$name" : 'Capture-Machine-\([0-9][0-9.]*\)-arm64\.dmg$')
dir=$(dirname "$image")
(cd "$dir" && shasum -a 256 "$name" gifski-1.34.0-source.tar.gz > SHA256SUMS)
hash=$(shasum -a 256 "$image" | cut -d' ' -f1)
mkdir -p Casks
cat > Casks/capture-machine.rb <<EOF
cask "capture-machine" do
  version "$version"
  sha256 "$hash"

  url "https://github.com/artisticmedic/capture-machine/releases/download/v#{version}/Capture-Machine-#{version}-arm64.dmg"
  name "Capture Machine"
  desc "Menu bar screen recorder for GIF and MP4 clips"
  homepage "https://timgailey.com/apps/capture-machine/"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Capture Machine.app"
end
EOF
echo "$dir/SHA256SUMS"

#!/bin/sh
# Package the source and build scripts for the separate encoder shipped with this release.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
export CARGO_HOME="$root/.build/gifski/cargo-home"
export PATH="$HOME/.cargo/bin:$PATH"
scripts/build-gifski.sh
dest=${1:-"$root/.build/distribution"}
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
work=$(mktemp -d "$root/.build/gifski/source.XXXXXX")
cd "$work"
crate=$(find "$CARGO_HOME/registry/cache" -name 'gifski-1.34.0.crate' -print -quit)
test -f "$crate"
tar -xzf "$crate"
cd gifski-1.34.0
mkdir -p .cargo
cargo vendor --locked --versioned-dirs vendor > .cargo/config.toml
cp "$root/Resources/gifski/LICENSE" .
cat > BUILD.txt <<'EOF'
Source for Capture Machine's gifski helper, including its locked dependencies.
On an Apple Silicon Mac with Rust and the Xcode Command Line Tools, cd into
this folder and run:
  export MACOSX_DEPLOYMENT_TARGET=15.0
  cargo build --offline --locked --release --no-default-features --features binary,gifsicle --bin gifski
The executable is target/release/gifski. Each dependency's source, manifest
and published license files are in vendor/.
EOF
tar -czf "$work/gifski-1.34.0-source.tar.gz" -C "$work" gifski-1.34.0
mv "$work/gifski-1.34.0-source.tar.gz" "$dest/"
echo "$dest/gifski-1.34.0-source.tar.gz"

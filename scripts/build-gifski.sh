#!/bin/sh
# Builds gifski 1.34.0 without FFmpeg into .build/gifski/out/bin/gifski, for build-app.sh to put in the app. Uses the
# Rust toolchain from rustup and keeps cargo's downloads in .build, so nothing outside the project changes.
set -eu
cd "$(dirname "$0")/.."
OUT="$PWD/.build/gifski/out"
export MACOSX_DEPLOYMENT_TARGET=15.0
export RUSTFLAGS="--remap-path-prefix=$PWD=."
build_key="1.34.0-binary,gifsicle-$(uname -m)-macos15-remapped-v1"
receipt="$OUT/$build_key.sha256"
if [ -f "$receipt" ] && (cd "$OUT" && shasum -a 256 -c "$build_key.sha256" >/dev/null 2>&1); then
  exit 0
fi
export CARGO_HOME="$PWD/.build/gifski/cargo-home"
export CARGO_TARGET_DIR="$PWD/.build/gifski/target"
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || { echo "cargo not found: install Rust with rustup" >&2; exit 1; }
cargo install --force gifski --version =1.34.0 --no-default-features --features binary,gifsicle --root "$OUT" --locked
(cd "$OUT" && shasum -a 256 bin/gifski > "$build_key.sha256")

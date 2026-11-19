#!/bin/sh
# Builds the Harper grammar library that the app links against. Needs Rust (https://rustup.rs).
set -e
cd "$(dirname "$0")/../Rust/chirp-harper"
# --locked: build with the versions in Cargo.lock, so Harper cannot change without the lock file changing.
PATH="$HOME/.cargo/bin:$PATH" cargo build --release --locked
mkdir -p ../lib
cp target/release/libchirp_harper.a ../lib/
echo "Built Rust/lib/libchirp_harper.a"

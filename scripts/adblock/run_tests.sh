#!/usr/bin/env bash
# Run the ad-blocking converter tests: Rust syntax-case tests (adblock-rust
# behaviour we depend on) and the Python post-processing/validation tests.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cargo test --locked --quiet --manifest-path "$here/converter/Cargo.toml"
python3 -m unittest discover -s "$here/tests" -v

#!/bin/zsh
# Gets a fresh clone ready to build: checks the tools, builds the Harper grammar library and generates
# Chirp.xcodeproj. Safe to run again at any time. Usage: Scripts/bootstrap.sh
set -e
cd "${0:A:h:h}"

step() { print -P "%B==> $1%b"; }
fail() { print -P "%F{red}$1%f"; exit 1; }

step "Checking the Mac"
[[ "$(uname -m)" == "arm64" ]] || fail "Chirp needs a Mac with Apple Silicon."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 26 )) || fail "Chirp needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

step "Checking Xcode"
xcode-select -p >/dev/null 2>&1 || fail "Install Xcode 27 from the App Store, open it once, then run this again."
xver=$(xcodebuild -version | head -1 | awk '{print $2}')
(( ${xver%%.*} >= 27 )) || fail "Chirp needs Xcode 27 or later (found $xver)."
if ! xcrun --find metal >/dev/null 2>&1 || ! xcrun metal --version >/dev/null 2>&1; then
  step "Downloading the Metal Toolchain (needed by MLX)"
  xcodebuild -downloadComponent MetalToolchain
fi

step "Checking XcodeGen"
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || fail "Install Homebrew (https://brew.sh) or XcodeGen (https://github.com/yonaskolb/XcodeGen), then run this again."
  brew install xcodegen
fi

step "Checking Rust"
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || fail "Install Rust with rustup (https://rustup.rs), then run this again."

lib=Rust/lib/libchirp_harper.a
if [[ -f $lib && -z $(find Rust/chirp-harper/src Rust/chirp-harper/Cargo.toml Rust/chirp-harper/Cargo.lock -newer $lib 2>/dev/null) ]]; then
  step "The Harper grammar library is up to date"
else
  step "Building the Harper grammar library"
  Scripts/build-harper.sh
fi

step "Generating Chirp.xcodeproj"
xcodegen generate --quiet

print -P "%F{green}Ready.%f Open Chirp.xcodeproj, or build from the command line as Docs/DEVELOPMENT.md shows."

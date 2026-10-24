#!/bin/sh
# Builds rust/out/HarborFFI.xcframework (static libharbor_ffi.a + header + module map) for
# Apple TV, iPhone and both simulators. Needs a Mac with Xcode. Usage: rust/build.sh [debug]
set -eu
cd "$(dirname "$0")"
here=$(pwd)
profile=release
[ "${1:-}" = "debug" ] && profile=debug
flag=""
[ "$profile" = "release" ] && flag="--release"

# Match the apps' minimum OS versions (project.yml) so the C parts of crates are built for them.
export TVOS_DEPLOYMENT_TARGET=17.0
export IPHONEOS_DEPLOYMENT_TARGET=26.0

targets="aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-ios aarch64-apple-ios-sim"
rustup target add $targets >/dev/null

cd harbor-ffi
for t in $targets; do
  echo "cargo build $profile --target $t"
  cargo build $flag --target "$t"
done

out="$here/out"
rm -rf "$out/HarborFFI.xcframework" "$out/headers"
mkdir -p "$out/headers"
cp include/harbor_ffi.h include/module.modulemap "$out/headers/"

args=""
for t in $targets; do
  args="$args -library target/$t/$profile/libharbor_ffi.a -headers $out/headers"
done
# shellcheck disable=SC2086
xcodebuild -create-xcframework $args -output "$out/HarborFFI.xcframework"
echo "rust/out/HarborFFI.xcframework"

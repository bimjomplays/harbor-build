#!/bin/sh
# Builds everything the Xcode project bundles that isn't committed: the engine bundle and the upstream art
# and translations (App/Generated/). Runs on Linux and macOS. Needs Node and the reference/harbor submodule.
set -eu
cd "$(dirname "$0")/.."
[ -f reference/harbor/package.json ] || git submodule update --init reference/harbor
cd engine
[ -d node_modules ] || npm ci --no-audit --no-fund
node build.mjs --min
cd ..
node tools/sync-upstream.mjs
mkdir -p App/Generated/Engine
# Release builds ship the minified bundle; Debug keeps names readable in engine stack traces.
if [ "${CONFIGURATION:-Release}" = "Debug" ]; then
  cp engine/dist/harbor-engine.js App/Generated/Engine/harbor-engine.js
else
  cp engine/dist/harbor-engine.min.js App/Generated/Engine/harbor-engine.js
fi
echo "App/Generated/Engine/harbor-engine.js ($(du -k App/Generated/Engine/harbor-engine.js | cut -f1) KB)"

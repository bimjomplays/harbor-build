#!/bin/sh
# Generates Harbor.xcodeproj from project.yml (macOS, needs XcodeGen).
# HARBOR_BUNDLE_ID and HARBOR_TEAM_ID come from the environment; CI sets them from repo settings.
set -eu
cd "$(dirname "$0")/.."
export HARBOR_BUNDLE_ID="${HARBOR_BUNDLE_ID:-org.example.harbor}"
export HARBOR_TEAM_ID="${HARBOR_TEAM_ID:-}"
xcodegen generate --spec project.yml

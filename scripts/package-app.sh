#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/dist/VideoBox.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

swift build -c release --package-path "$PROJECT_ROOT"

mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$PROJECT_ROOT/.build/out/Products/Release/VideoBox" "$MACOS_PATH/VideoBox"
cp "$PROJECT_ROOT/Support/Info.plist" "$CONTENTS_PATH/Info.plist"
cp "$PROJECT_ROOT/Support/AppIcon.icns" "$RESOURCES_PATH/AppIcon.icns"

if [[ -n "${VIDEOBOX_HANDBRAKE_CLI:-}" && -x "${VIDEOBOX_HANDBRAKE_CLI}" ]]; then
    cp "$VIDEOBOX_HANDBRAKE_CLI" "$RESOURCES_PATH/HandBrakeCLI"
    cli_source_dir="$(cd "$(dirname "$VIDEOBOX_HANDBRAKE_CLI")" && pwd)"
    if [[ -d "$cli_source_dir/doc" ]]; then
        cp -R "$cli_source_dir/doc" "$RESOURCES_PATH/HandBrake"
    fi
    cp "$PROJECT_ROOT/Vendor/HandBrake-1.11.2.md" "$RESOURCES_PATH/HandBrake-VideoBox-Notice.md"
    cp "$PROJECT_ROOT/THIRD-PARTY-NOTICES.md" "$RESOURCES_PATH/VideoBox-Third-Party-Notices.md"
    echo "Bundled HandBrakeCLI from VIDEOBOX_HANDBRAKE_CLI"
else
    echo "HandBrakeCLI not bundled. Set VIDEOBOX_HANDBRAKE_CLI to package it." >&2
fi

echo "Built $APP_PATH"

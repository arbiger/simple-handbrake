# Video Box handoff

Updated: 2026-09-21

## Current state

The MVP is implemented as a native macOS SwiftUI app and has been built and
smoke-tested from the project root.

The visible packaged development app is:

`dist/VideoBox.app`

It uses the bundled local HandBrakeCLI runtime at:

`dist/VideoBox.app/Contents/Resources/HandBrakeCLI`

## User workflow

1. Drag one or more supported video files into the input area.
2. Review the queue and generated `<stem>-decoded.mp4` names.
3. Press `Convert`.
4. The app processes one file at a time and leaves originals untouched.

The output policy is fixed for the MVP:

- preset: `Very Fast 1080p30`;
- container: MP4;
- output folder: source folder;
- existing output: skip, never overwrite;
- generated `-decoded` files: ignored when dropped back into the app.

While a queue is active, the current task position is shown as `n/total` in
the window title bar and as a badge on the Dock icon. For example, the second
active file in a seven-file queue shows `2/7`.

Closing the window with the red button leaves the app running so an active
conversion can continue. Activating the Video Box app again reopens the main
window and preserves the in-memory queue.

## Build and run

From the project root:

```sh
swift build
swift run VideoBox
```

To build the packaged app with the locally cached HandBrakeCLI:

```sh
VIDEOBOX_HANDBRAKE_CLI="$PWD/.build/vendor/HandBrakeCLI-1.11.2/HandBrakeCLI" \
  scripts/package-app.sh
open "$PWD/dist/VideoBox.app"
```

The package script also copies the HandBrake documentation, runtime notice, and
third-party notice into the app resources.

## Repository map

```text
Sources/VideoBox/main.swift       SwiftUI UI, queue model, and CLI runner
Support/Info.plist                 macOS app metadata
Support/AppIconSource.png         Supplied source icon image
Support/AppIcon.icns               Generated macOS app icon
Vendor/HandBrake-1.11.2.md        Runtime lineage and licensing record
THIRD-PARTY-NOTICES.md             Upstream HandBrake and runtime notices
scripts/package-app.sh             Development app bundling script
docs/DEV-LOG.md                    Dated project history and evidence
docs/HANDOFF.md                    This current handoff
.build/                            Ignored generated builds, QA, and runtime cache
```

## Evidence already checked

- `swift build` succeeds.
- `swift build -c release` succeeds.
- `dist/VideoBox.app` launches locally.
- The red close button leaves the process running and a subsequent app
  activation reopens the main window.
- The Dock badge and window title use the current queue position format `n/total`.
- The bundled CLI reports HandBrake `1.11.2`.
- A two-second test encode completed successfully and produced H.264/AAC MP4.
- The old project path is clear after relocation.

## Known limits

- The app bundle is currently an unsigned development build.
- The source tree is arm64 for the current Apple Silicon machine; the bundled
  HandBrakeCLI itself is universal.
- The current local runtime comes from the official 1.11.2 CLI release. A
  reproducible source build should be completed once full Xcode is available;
  the HandBrake macOS build guide requires Xcode for that workflow.
- No real user video has yet been processed by the UI; only the CLI path and a
  generated test video have been verified.
- There is no advanced preset selector yet by design.
- macOS's Dock hover tooltip remains the app name; progress is shown directly
  in the Dock badge because AppKit exposes a custom badge string, not a custom
  dynamic hover tooltip.

The visible app bundle is intentionally kept in `dist/`; `.build/` remains an
implementation cache and intermediate build area.

## Recommended next work

1. Run the app on a small set of real videos with spaces and Unicode filenames.
2. Verify output playback, resolution limits, audio tracks, and collision behavior.
3. Add focused model/runner tests and a deterministic test CLI fixture.
4. Build HandBrakeCLI from the pinned source tag and record the exact build command.
5. Add code signing, notarization, and a distributable corresponding-source
   package for the bundled HandBrake runtime.
6. Consider an optional advanced preset menu only after the fixed workflow is stable.

## Licensing boundary

Video Box is a separate frontend. HandBrake and its bundled dependencies keep
their own GPLv2 and third-party license obligations. Preserve the app resources
under `Contents/Resources/HandBrake`, the runtime notice, and the third-party
notice when redistributing a bundled build.

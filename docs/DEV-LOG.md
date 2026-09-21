# Development log

## 2026-09-17 — Initial product decision

- Scope: a small local macOS drag-and-drop frontend for HandBrake.
- Main workflow: drop multiple videos, press one button, process the queue sequentially.
- Preset: fixed `Very Fast 1080p30`; no preset picker in the MVP.
- Output: same source folder, `<stem>-decoded.mp4`.
- Safety: originals are untouched; an existing output is skipped rather than overwritten.
- Runtime: bundle HandBrakeCLI so normal conversion does not require a network connection or a separate HandBrake installation.

## 2026-09-17 — MVP implementation

- Added a Swift Package executable targeting macOS 13 and later.
- Added the SwiftUI window with:
  - drag-and-drop input area;
  - file chooser;
  - queue rows with size, output name, status, and progress;
  - sequential conversion and cancellation;
  - fixed preset/output summary.
- Added a `Process` runner for local `HandBrakeCLI` execution.
- Added JSON/percentage progress parsing and failure/skip handling.
- Added `.app` packaging metadata and `scripts/package-app.sh`.

## 2026-09-17 — HandBrake runtime verification

- Used the official Apple Silicon CLI release `HandBrakeCLI 1.11.2`, matching the installed HandBrake GUI version.
- Verified the bundled CLI reports version `1.11.2` and exposes `Very Fast 1080p30`.
- Converted a generated two-second test video:
  - input: `.build/qa/clip.mov`;
  - output: `.build/qa/clip-decoded.mp4`;
  - verified output: H.264 video, AAC audio, 640×360, 30 fps, MP4 container.
- Verified the packaged executable launches as `dist/VideoBox.app`.
- Included HandBrake documentation and the project runtime notice in the app resources.

## 2026-09-17 — Project relocation

- Moved the complete Git worktree into the current project directory.
- The destination initially contained only an empty `docs/` directory; it was preserved during the move.
- No source, Git metadata, build cache, test output, or runtime artifact was deleted.
- The old working location is clear and the Git root resolves to the project directory.

## 2026-09-17 — Visible app output

- Kept `.build/` as the hidden SwiftPM build cache.
- Changed the user-facing package destination to visible `dist/VideoBox.app`.
- Added `dist/` to `.gitignore` because it is a generated app bundle.

## 2026-09-17 — App icon

- Added the supplied clapperboard/play image as `Support/AppIconSource.png`.
- Generated the macOS iconset and `Support/AppIcon.icns` at the required sizes.
- Updated the app bundle metadata and window header to use the supplied icon.

## 2026-09-19 — Window reopen and visible queue progress

- Added an AppKit application delegate for the SwiftUI app.
- The app now remains running after the red close button closes the last window,
  and activating the app again reopens the main `WindowGroup` instead of
  requiring a quit/relaunch cycle.
- Added a current-task progress string based on queue position: the second
  active job in a seven-job queue is `2/7`.
- Added `2/7` to the window title bar and to the macOS Dock tile badge.
- Verified the visible app launch, red close button, background process, and
  reactivation flow with the packaged `dist/VideoBox.app`.
- The Dock badge is the supported system-visible progress surface; macOS keeps
  the pointer-hover tooltip as the application name.

## Next log entry

Record the first real-user-video test, including source path type, output path,
CLI exit status, playback/codec verification, and any filename or permission
edge cases.

## 2026-09-21 — Publication hygiene and upstream credit

- Added an explicit HandBrake acknowledgement and pinned-runtime record for a
  future public repository.
- Added `THIRD-PARTY-NOTICES.md` with HandBrake source, release, GPLv2, and
  third-party acknowledgement links.
- Kept the HandBrakeCLI binary, release archive, generated app, and local build
  cache out of Git.
- Removed machine-specific absolute paths from the project record before
  publication.

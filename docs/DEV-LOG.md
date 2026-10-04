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

## 2026-09-21 — Publication hygiene and upstream credit

- Added an explicit HandBrake acknowledgement and pinned-runtime record for a
  future public repository.
- Added `THIRD-PARTY-NOTICES.md` with HandBrake source, release, GPLv2, and
  third-party acknowledgement links.
- Kept the HandBrakeCLI binary, release archive, generated app, and local build
  cache out of Git.
- Removed machine-specific absolute paths from the project record before
  publication.

## 2026-09-25 — Compact layout and product name

- Replaced the two-level branded header with one `Simple HandBrake Converter`
  heading and a short description beneath it.
- Moved preset, output location, overwrite policy, and Convert action into one
  top controls row.
- Added Clear All to the queue header and disabled it while converting.
- Matched the input and queue panel heights, removed the duplicate file picker,
  and tightened spacing.
- Updated the visible macOS app name and package path to
  `dist/Simple HandBrake Converter.app`.

## 2026-09-29 — Queue controls and panel alignment

- Moved output location and existing-output policy alongside the preset.
- Added a Clear All queue action, disabled when the queue is empty or active.
- Set a shared minimum height for the input and queue panels.
- Removed the duplicate Choose files control; Add files remains in the input
  panel header.

## 2026-09-29 — Matched panel height and tighter window

- Set the input drop area and queue card to the same fixed height so their
  outside edges align even when the queue is empty.
- Reduced the drop area's unused vertical space, page spacing, and padding.
- Lowered the window's minimum height and set a more compact initial size to
  remove the large empty band below the progress bar.

## 2026-10-03 — Per-job conversion logs

- Retained HandBrakeCLI output for failed jobs and added a log viewer to each
  failed queue row.
- Included the exit code, input/output paths, preset, completion time, and
  combined CLI output in the diagnostic view.
- Added Copy Log and Save Log actions. Logs stay in the in-memory queue unless
  the user explicitly saves one; nothing is uploaded or written automatically.

## 2026-10-04 — Log files on disk with Open button

- Every finished conversion now writes a log file automatically to
  `~/Library/Logs/Simple HandBrake Converter/`, for successful and failed
  jobs alike, so records survive quitting the app and clearing the queue.
- Log file names follow
  `name_originalSize_compressedSize_yyyy-MM-dd-HH-mm-ss.log`, for example
  `Holiday2024_4.2GB_1.1GB_2026-10-04-18-30-45.log`. Failed jobs use `NA`
  for the compressed size.
- Log contents record the result and exit code, input and output paths, both
  sizes, the preset, the finish timestamp, and the full combined HandBrakeCLI
  output.
- Added an Open Log button and a view sheet on every queue row that has a log,
  plus a folder button in the queue header to open the logs directory.
- Successful jobs no longer discard their CLI output, so their logs can be
  inspected too.
- The old Save Log dialog was removed; the file already exists on disk.
- Logs contain local file paths. They stay on the machine and are never
  uploaded.

## 2026-10-04 — Single logs window, newest first

- Replaced the per-row log buttons and single-log sheet with one Logs window
  opened from a single Logs button in the queue header.
- The window reads the log folder from disk, so it lists past sessions as well
  as the current queue, sorted newest first with the newest entry selected on
  open.
- Each row shows the source name, finish timestamp, original size, and
  compressed size, with a green or red dot for the result. Selecting a row
  shows the full log text.
- The window keeps Refresh, Open Log, Reveal in Finder, Copy, and Open Logs
  Folder.
- Verified the reader against three real log files written out of order: they
  listed newest first and the header fields parsed correctly, including a
  source filename containing a colon.

## Next log entry

Record the first real-user-video test, including source path type, output path,
CLI exit status, playback/codec verification, and any filename or permission
edge cases.

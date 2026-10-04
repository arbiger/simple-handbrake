# Simple HandBrake Converter

Compact macOS drag-and-drop frontend for local HandBrake batch conversion.

## Current MVP

- Drag multiple video files into one queue.
- Use the fixed `Very Fast 1080p30` preset.
- Write `<original-name>-decoded.mp4` beside each source file.
- Skip an output that already exists.
- Clear the whole queue at once while conversion is idle.
- Process one file at a time and show progress.
- Keep the originals untouched.

The visible packaged app is `dist/Simple HandBrake Converter.app`. It contains `HandBrakeCLI` at `Simple HandBrake Converter.app/Contents/Resources/HandBrakeCLI`. During development, the CLI may also be available at `/opt/homebrew/bin/HandBrakeCLI` or `/usr/local/bin/HandBrakeCLI`.

The app icon uses the supplied clapperboard/play artwork from `Support/AppIconSource.png`.

When a batch is running, the current queue position appears in the window title and the Dock icon badge, for example `2/7`. Closing the window with the red button keeps the app alive; activating the app again reopens the main window.

Project records are in [`docs/`](docs/), including the [development log](docs/DEV-LOG.md) and [handoff](docs/HANDOFF.md).

## Built on HandBrake

Simple HandBrake Converter is an independent macOS frontend around the HandBrake
command-line engine. It is not affiliated with, endorsed by, or a replacement
for the HandBrake project. Many thanks to the HandBrake contributors and the
upstream projects that make the encoding engine possible.

The pinned runtime record is in [`Vendor/HandBrake-1.11.2.md`](Vendor/HandBrake-1.11.2.md),
and the full third-party distribution note is in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

## Build

```sh
swift build
swift run VideoBox
```

To point a development build at a local CLI without changing the app:

```sh
VIDEOBOX_HANDBRAKE_CLI=/path/to/HandBrakeCLI swift run VideoBox
```

## Licensing

The frontend source in this repository is licensed under the GNU
General Public License, version 2.0 only; see LICENSE.

This app is a separate frontend. HandBrake and its bundled dependencies retain
their own GPLv2 and third-party license terms. This repository does not include
the HandBrakeCLI binary or release archive; generated app bundles and local
runtime caches are intentionally excluded from Git.

Any distributed package that bundles HandBrakeCLI must preserve the relevant
license and third-party notices and provide the corresponding source
information required by those licenses. See
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) before redistributing a
packaged app.

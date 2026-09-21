# Third-party notices

## HandBrake

Video Box uses the HandBrake command-line engine as a local runtime.

- Project: <https://github.com/HandBrake/HandBrake>
- Pinned release: `1.11.2`
- Source tag: `1.11.2`
- Source commit: `9c86c92f58acf3f288f7fd1a2389c6c5fdcd5a84`
- Release record: <https://github.com/HandBrake/HandBrake/releases/tag/1.11.2>
- License information: <https://github.com/HandBrake/HandBrake/blob/master/LICENSE>
- HandBrake license text: <https://github.com/HandBrake/HandBrake/blob/master/COPYING>
- Third-party acknowledgements: <https://github.com/HandBrake/HandBrake/blob/master/THANKS.markdown>

HandBrake's repository states that most of its files are under the GNU General
Public License Version 2 and that a compiled HandBrake build is licensed under
GPLv2. HandBrake also incorporates separately licensed third-party libraries;
those terms remain applicable to the runtime.

This repository contains the Video Box frontend and packaging scripts, not the
HandBrakeCLI binary, its release archive, or a copy of the HandBrake source
tree. `.build/` and `dist/` are ignored so a local runtime or app bundle is not
uploaded accidentally.

Before distributing a packaged app that bundles HandBrakeCLI, retain the
upstream license and third-party notices and provide the corresponding source
information required by the applicable licenses. The package script copies the
project's runtime records into the app resources when a local HandBrakeCLI is
supplied.

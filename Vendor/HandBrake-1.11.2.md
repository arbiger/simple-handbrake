# HandBrake runtime

Simple HandBrake Converter uses the HandBrake command-line engine as a bundled local runtime.

Simple HandBrake Converter is an independent frontend and is not affiliated with or endorsed by
HandBrake. It invokes HandBrakeCLI as a local process; it does not include the
HandBrake source tree in this repository.

- Version: `1.11.2`
- Apple Silicon release asset: `HandBrakeCLI-1.11.2.dmg`
- Source tag: `1.11.2`
- Source commit: `9c86c92f58acf3f288f7fd1a2389c6c5fdcd5a84`
- Project: https://github.com/HandBrake/HandBrake
- Release: https://github.com/HandBrake/HandBrake/releases/tag/1.11.2

The binary and all required runtime libraries must remain under HandBrake's
own GPL and third-party license terms. The release asset is intentionally kept
out of Git; the packaging step supplies it from a local build/download cache.

When redistributing a package that includes this runtime, preserve the
HandBrake license, third-party notices, and corresponding source information.
See the repository-level `THIRD-PARTY-NOTICES.md` for the project record.

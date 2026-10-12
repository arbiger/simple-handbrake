import Foundation

struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RegressionFailure(description: message) }
}

func waitFor(
    _ description: String,
    timeout: TimeInterval = 4,
    condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw RegressionFailure(description: "Timed out waiting for \(description)")
}

let fileManager = FileManager.default
guard CommandLine.arguments.count == 2 else {
    throw RegressionFailure(description: "Usage: swift scripts/lifecycle-regression.swift /path/to/main.swift")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let root = fileManager.temporaryDirectory
    .appendingPathComponent("simple-handbrake-regression-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: root) }

func writeExecutable(_ url: URL, _ contents: String) throws {
    try Data(contents.utf8).write(to: url)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func run(_ executable: URL, environment: [String: String]) throws {
    let process = Process()
    process.executableURL = executable
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RegressionFailure(description: "Harness subprocess failed with status \(process.terminationStatus)")
    }
}

func runCommand(_ path: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RegressionFailure(description: "\(path) failed with status \(process.terminationStatus)")
    }
}

let source = try String(contentsOf: sourceURL, encoding: .utf8)
guard let start = source.range(of: "enum ConversionStatus: Equatable {"),
      let end = source.range(of: "struct ContentView: View {") else {
    throw RegressionFailure(description: "Could not locate the model boundaries in main.swift")
}
var modelSource = String(source[start.lowerBound..<end.lowerBound])
let originalLogDirectory = """
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
    }
"""
let temporaryLogDirectory = """
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARNESS_LOG_DIRECTORY"]!, isDirectory: true)
    }
"""
guard modelSource.contains(originalLogDirectory) else {
    throw RegressionFailure(description: "Could not isolate ConversionLog.directory")
}
modelSource.replaceSubrange(
    modelSource.range(of: originalLogDirectory)!,
    with: temporaryLogDirectory
)
guard let progressMethod = modelSource.range(of: "    private func updateSystemProgress() {"),
      let methodEnd = modelSource.range(of: "\n    }\n}", range: progressMethod.lowerBound..<modelSource.endIndex) else {
    throw RegressionFailure(description: "Could not isolate AppKit progress presentation")
}
modelSource.replaceSubrange(progressMethod.lowerBound..<methodEnd.upperBound, with: "    private func updateSystemProgress() {}\n}")

let harness = #"""

@main
struct LifecycleHarness {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARNESS_ROOT"]!, isDirectory: true)
        if ProcessInfo.processInfo.environment["HARNESS_CASE"] == "launch" {
            try await launchFailure(root: root)
        } else {
            try await allCases(root: root)
        }
    }

    @MainActor
    static func waitForIdle(_ model: VideoBoxModel) async throws {
        try await waitFor("conversion finalization") { !model.isConverting }
    }

    @MainActor
    static func add(_ name: String, to model: VideoBoxModel, under directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent(name)
        try Data("fake input".utf8).write(to: input)
        model.add(urls: [input])
        return input
    }

    @MainActor
    static func log(for job: ConversionJob) throws -> String {
        guard let url = job.logURL else { throw RegressionFailure(description: "No persistent log for \(job.inputURL.lastPathComponent)") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    static func allCases(root: URL) async throws {
        let manager = FileManager.default

        // The actual ConversionLog writer must write in this isolated folder,
        // preserve its first file, and use the UUID to disambiguate equal metadata.
        let logDirectory = ConversionLog.directory
        try manager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let sameTime = Date(timeIntervalSince1970: 1_800_000_000)
        let longName = String(repeating: "界", count: 70) + ".mp4"
        func sampleJob(_ name: String, id: UUID) -> ConversionJob {
            var job = ConversionJob(
                id: id,
                inputURL: URL(fileURLWithPath: "/tmp/\(name)"),
                outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
                fileSize: 4_000_000
            )
            job.exitStatus = 0
            job.outputSize = 1_000_000
            job.finishedAt = sameTime
            job.logOutput = "writer check"
            return job
        }
        let first = sampleJob(longName, id: UUID())
        let second = sampleJob(longName, id: UUID())
        let firstURL = try ConversionLog.write(for: first).unwrap("Atomic no-overwrite log write failed")
        let secondURL = try ConversionLog.write(for: second).unwrap("Second unique log write failed")
        try require(firstURL != secondURL, "Equal basename, byte sizes, and timestamp collided")
        let stem = firstURL.deletingPathExtension().lastPathComponent.components(separatedBy: "_").first ?? ""
        try require(stem.utf8.count <= 80, "Unicode stem exceeded 80 UTF-8 bytes")
        let original = try Data(contentsOf: firstURL)
        try require(ConversionLog.write(for: first) == nil, "Repeated job UUID overwrote an existing log")
        let unchangedLog = try Data(contentsOf: firstURL)
        try require(unchangedLog == original, "Existing log contents changed after collision")

        let cancellationDirectory = root.appendingPathComponent("cancel-videos", isDirectory: true)
        let cancellationModel = VideoBoxModel()
        let cancelledInput = try add("cancel.mp4", to: cancellationModel, under: cancellationDirectory)
        let remainingInput = try add("remaining.mp4", to: cancellationModel, under: cancellationDirectory)
        cancellationModel.start()
        do {
            try await waitFor("live progress before child exit", timeout: 2) {
                cancellationModel.jobs.first?.progress == 0.25
            }
        } catch {
            cancellationModel.cancel()
            try? await waitForIdle(cancellationModel)
            throw RegressionFailure(description: "Small progress line was not observable while fake CLI remained alive")
        }
        let cancelledJob = cancellationModel.jobs[0]
        try require(manager.fileExists(atPath: cancelledJob.outputURL.path), "Fake CLI did not create its partial output")
        cancellationModel.cancel()
        try await waitForIdle(cancellationModel)
        let afterCancel = cancellationModel.jobs
        try require(afterCancel[0].status == .failed, "Cancelled job did not finalize as failed/cancelled")
        try require(!manager.fileExists(atPath: afterCancel[0].outputURL.path), "Cancellation left its partial output")
        try require(afterCancel[1].inputURL == remainingInput && afterCancel[1].status == .ready, "Remaining job was not restored to Ready")
        let cancellationLog = try log(for: afterCancel[0])
        try require(cancellationLog.contains("Result: Cancelled"), "Cancellation result was absent from saved log")
        try require(cancellationLog.contains("live-progress"), "Cancellation log omitted captured progress output")
        try require(cancellationLog.contains("Partial output removed"), "Cancellation cleanup result was absent from saved log")
        _ = cancelledInput

        let tailDirectory = root.appendingPathComponent("tail-videos", isDirectory: true)
        let tailModel = VideoBoxModel()
        _ = try add("tail.mp4", to: tailModel, under: tailDirectory)
        tailModel.start()
        try await waitForIdle(tailModel)
        let tailJob = tailModel.jobs[0]
        try require(tailJob.status == .failed && tailJob.exitStatus == 4, "Burst fake CLI did not retain its nonzero exit status")
        let tailLog = try log(for: tailJob)
        try require(tailLog.contains("FINAL_尾"), "Split UTF-8 final tail was corrupted or lost")
        try require(tailLog.contains("stderr-tail"), "Final stderr tail was lost")
        try require(tailLog.contains("burst-07999"), "Burst output was truncated")
        try require(!manager.fileExists(atPath: tailJob.outputURL.path), "Failed conversion partial output was not removed")

        let cleanupDirectory = root.appendingPathComponent("cleanup-videos", isDirectory: true)
        try manager.createDirectory(at: cleanupDirectory, withIntermediateDirectories: true)
        let cleanupInput = cleanupDirectory.appendingPathComponent("cleanup.mp4")
        try Data("fake input".utf8).write(to: cleanupInput)
        let cleanupModel = VideoBoxModel()
        cleanupModel.add(urls: [cleanupInput])
        cleanupModel.start()
        let marker = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARNESS_MARKER"]!)
        try await waitFor("cleanup fixture output", timeout: 3) { manager.fileExists(atPath: marker.path) }
        let cleanupOutput = cleanupModel.jobs[0].outputURL
        try runCommand("/usr/bin/chflags", arguments: ["uchg", cleanupOutput.path])
        let release = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARNESS_RELEASE"]!)
        try Data().write(to: release)
        try await waitForIdle(cleanupModel)
        try runCommand("/usr/bin/chflags", arguments: ["nouchg", cleanupOutput.path])
        let cleanupJob = cleanupModel.jobs[0]
        try require(cleanupJob.status == .failed && manager.fileExists(atPath: cleanupOutput.path), "Removal-failure fixture did not preserve the partial")
        try require(cleanupJob.detail.contains("Partial output cleanup failed"), "Queue detail falsely reported or omitted cleanup failure")
        try require(cleanupModel.lastMessage?.contains("Partial output cleanup failed") == true, "UI-level cleanup failure message was missing")
        let cleanupLog = try log(for: cleanupJob)
        try require(cleanupLog.contains("Details: ") && cleanupLog.contains("Partial output cleanup failed"), "Saved log omitted the removal error")

        let successDirectory = root.appendingPathComponent("success-videos", isDirectory: true)
        let successModel = VideoBoxModel()
        _ = try add("success.mp4", to: successModel, under: successDirectory)
        successModel.start()
        try await waitForIdle(successModel)
        let successJob = successModel.jobs[0]
        try require(successJob.status == .done && successJob.exitStatus == 0, "Successful fake conversion did not finish successfully")
        try require(manager.fileExists(atPath: successJob.outputURL.path), "Successful conversion output was missing")
        let successLog = try log(for: successJob)
        try require(successLog.contains("Result: Exit code 0") && successLog.contains("successful-tail"), "Successful conversion output was not saved in its log")

        let skipDirectory = root.appendingPathComponent("skip-videos", isDirectory: true)
        let skipModel = VideoBoxModel()
        _ = try add("already.mp4", to: skipModel, under: skipDirectory)
        let existingOutput = skipModel.jobs[0].outputURL
        try manager.createDirectory(at: existingOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep existing".utf8).write(to: existingOutput)
        skipModel.start()
        try require(skipModel.jobs[0].status == .skipped, "Preexisting output was not skipped")
        let preservedOutput = try Data(contentsOf: existingOutput)
        try require(preservedOutput == Data("keep existing".utf8), "Preexisting output was changed")

        print("PASS: actual log writer uses isolated directory, unique UUID names, byte-safe Unicode stem, and no overwrite")
        print("PASS: live progress arrives before child exit; cancellation logs and removes partial output; remaining job returns Ready")
        print("PASS: burst exit-4 output, split UTF-8 stdout, and final stderr tail are saved")
        print("PASS: cleanup failure remains visible in queue detail, last message, and persistent log")
        print("PASS: successful conversion is logged and preexisting output remains skipped/preserved")
    }

    @MainActor
    static func launchFailure(root: URL) async throws {
        let model = VideoBoxModel()
        _ = try add("launch.mp4", to: model, under: root.appendingPathComponent("launch-videos", isDirectory: true))
        model.start()
        try await waitFor("launch error finalization") { !model.isConverting }
        let job = model.jobs[0]
        try require(job.status == .failed, "Process.run launch failure did not mark job failed")
        try require(job.errorMessage != nil, "Launch failure was not reported")
        let contents = try log(for: job)
        try require(contents.contains("Result:") && contents.contains(job.errorMessage!), "Launch failure was not persisted")
        print("PASS: Process.run launch failure closes the pipe and finalizes with a saved diagnostic")
    }
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw RegressionFailure(description: message) }
        return value
    }
}
"""#

let generatedSource = """
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

private enum AppIdentity {
    static let name = "Simple HandBrake Converter"
}

struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

func runCommand(_ path: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RegressionFailure(description: "\\(path) failed with status \\(process.terminationStatus)")
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw NSError(domain: "LifecycleRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func waitFor(_ description: String, timeout: TimeInterval = 4, condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "LifecycleRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \\(description)"])
}

""" + modelSource + "\n" + harness
let generatedURL = root.appendingPathComponent("LifecycleHarness.swift")
let executableURL = root.appendingPathComponent("LifecycleHarness")
try generatedSource.write(to: generatedURL, atomically: true, encoding: .utf8)

let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-parse-as-library", generatedURL.path, "-o", executableURL.path]
try compiler.run()
compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else {
    throw RegressionFailure(description: "Could not compile actual-model lifecycle harness")
}

let fakeCLI = root.appendingPathComponent("fake-handbrake")
try writeExecutable(fakeCLI, #"""
#!/bin/bash
set -u
input=""
output=""
while (($#)); do
  case "$1" in
    -i) input="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
name="${input##*/}"
case "$name" in
  cancel.mp4)
    printf 'partial' > "$output"
    printf '{"Progress": 0.25}\nlive-progress\n'
    exec /bin/sleep 8
    ;;
  tail.mp4)
    printf 'partial' > "$output"
    for ((i=0; i<8000; i++)); do printf 'burst-%05d diagnostic payload for pipe draining\n' "$i"; done
    printf 'FINAL_'
    printf '\xe5'
    /bin/sleep 0.03
    printf '\xb0'
    /bin/sleep 0.03
    printf '\xbe\n'
    printf 'stderr-tail\n' >&2
    exit 4
    ;;
  cleanup.mp4)
    printf 'partial' > "$output"
    : > "$HARNESS_MARKER"
    while [ ! -e "$HARNESS_RELEASE" ]; do /bin/sleep 0.02; done
    echo cleanup-failure-case
    exit 4
    ;;
  *)
    printf 'completed' > "$output"
    printf 'successful-tail\n'
    exit 0
    ;;
esac
"""#)

let brokenCLI = root.appendingPathComponent("broken-handbrake")
try writeExecutable(brokenCLI, "#!/missing/lifecycle-regression-interpreter\n")
let marker = root.appendingPathComponent("cleanup-ready")
let release = root.appendingPathComponent("cleanup-release")

let common = [
    "HARNESS_ROOT": root.path,
    "VIDEOBOX_HANDBRAKE_CLI": fakeCLI.path
]
try run(executableURL, environment: common.merging([
    "HARNESS_CASE": "all",
    "HARNESS_LOG_DIRECTORY": root.appendingPathComponent("logs-main", isDirectory: true).path,
    "HARNESS_MARKER": marker.path,
    "HARNESS_RELEASE": release.path
]) { _, new in new })
try run(executableURL, environment: common.merging([
    "HARNESS_CASE": "launch",
    "VIDEOBOX_HANDBRAKE_CLI": brokenCLI.path,
    "HARNESS_LOG_DIRECTORY": root.appendingPathComponent("logs-launch", isDirectory: true).path
]) { _, new in new })

print("PASS: fake CLI lifecycle regression suite completed in an isolated temporary root (cleaned on exit)")

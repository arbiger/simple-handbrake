import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private enum AppIdentity {
    static let name = "Simple HandBrake Converter"
}

@main
struct VideoBoxApp: App {
    @NSApplicationDelegateAdaptor(VideoBoxAppDelegate.self) private var appDelegate
    private let model = VideoBoxModel()

    var body: some Scene {
        WindowGroup(AppIdentity.name, id: "main") {
            ContentView(model: model, appDelegate: appDelegate)
                .frame(minWidth: 820, minHeight: 430)
        }
        .defaultSize(width: 1050, height: 460)
    }
}

final class VideoBoxAppDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sender.activate(ignoringOtherApps: true)

        if flag {
            sender.windows.first(where: { $0.isKeyWindow })?.makeKeyAndOrderFront(nil)
            return false
        }

        // A SwiftUI WindowGroup normally keeps the NSWindow object around after
        // the red close button is pressed. Reuse it when possible.
        if let window = sender.windows.first(where: { !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
            return false
        }

        // If SwiftUI has released the window, ask the identified WindowGroup to
        // create it again through the openWindow action registered by ContentView.
        if let reopenMainWindow {
            DispatchQueue.main.async {
                reopenMainWindow()
                sender.activate(ignoringOtherApps: true)
            }
            return false
        }

        return true
    }
}

enum ConversionStatus: Equatable {
    case ready
    case waiting
    case running
    case done
    case skipped
    case failed

    var label: String {
        switch self {
        case .ready: "Ready"
        case .waiting: "Waiting"
        case .running: "Converting"
        case .done: "Done"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

struct ConversionJob: Identifiable, Equatable {
    let id: UUID
    let inputURL: URL
    let outputURL: URL
    let fileSize: Int64?
    var status: ConversionStatus = .ready
    var progress: Double = 0
    var detail: String = ""
    var errorMessage: String?
    var exitStatus: Int32?
    var finishedAt: Date?
    var logOutput: String = ""
    var outputSize: Int64?
    var logURL: URL?

    var fileType: String {
        let value = inputURL.pathExtension.uppercased()
        return value.isEmpty ? "FILE" : value
    }
}

/// A log file that is already on disk, ready to list in the logs window.
struct LogEntry: Identifiable, Equatable {
    let id: URL
    let name: String
    let result: String
    let inputSize: String
    let outputSize: String
    let finished: String
    let modifiedAt: Date
    let contents: String

    var isSuccess: Bool { result == "Exit code 0" }
}

/// One log file per finished conversion, written to the shared macOS log
/// folder so it survives quitting the app and clearing the queue.
@MainActor
private enum ConversionLog {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = unit == 0 ? String(Int(value)) : String(format: "%.1f", value)
        return number + units[unit]
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: date)
    }

    static func resultDescription(for job: ConversionJob) -> String {
        guard let exitStatus = job.exitStatus else { return job.errorMessage ?? "Failed" }
        if exitStatus == 4 { return "Exit code 4 — Unknown Error (best effort)" }
        return "Exit code \(exitStatus)"
    }

    /// name_originalSize_compressedSize_yyyy-MM-dd-HH-mm-ss.log
    static func fileName(for job: ConversionJob) -> String {
        let stem = job.inputURL.deletingPathExtension().lastPathComponent
        let cleaned = stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeStem = String((cleaned.isEmpty ? "video" : cleaned).prefix(80))
        let input = job.fileSize.map(sizeLabel) ?? "Unknown"
        let output = job.outputSize.map(sizeLabel) ?? "NA"
        let stamp = timestamp(job.finishedAt ?? Date())
        return "\(safeStem)_\(input)_\(output)_\(stamp).log"
    }

    static func contents(for job: ConversionJob) -> String {
        [
            "\(AppIdentity.name) — conversion log",
            "Result: \(resultDescription(for: job))",
            "Input: \(job.inputURL.path)",
            "Input size: \(job.fileSize.map(sizeLabel) ?? "Unknown")",
            "Output: \(job.outputURL.path)",
            "Output size: \(job.outputSize.map(sizeLabel) ?? "Not produced")",
            "Preset: \(VideoBoxModel.preset)",
            "Finished: \(job.finishedAt.map(timestamp) ?? "Unknown")",
            "",
            "--- HandBrakeCLI output ---",
            job.logOutput.isEmpty ? (job.errorMessage ?? "No output was captured.") : job.logOutput
        ].joined(separator: "\n")
    }

    @discardableResult
    static func write(for job: ConversionJob) -> URL? {
        let folder = directory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(fileName(for: job))
            try contents(for: job).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Every log on disk, newest first.
    static func entries() -> [LogEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "log" }
            .compactMap(read)
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Reads back the header lines written by `contents(for:)`.
    private static func read(_ url: URL) -> LogEntry? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])

        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }

        let input = fields["Input"] ?? ""
        return LogEntry(
            id: url,
            name: input.isEmpty
                ? url.deletingPathExtension().lastPathComponent
                : URL(fileURLWithPath: input).lastPathComponent,
            result: fields["Result"] ?? "Unknown",
            inputSize: fields["Input size"] ?? "Unknown",
            outputSize: fields["Output size"] ?? "Not produced",
            finished: fields["Finished"] ?? "Unknown",
            modifiedAt: modified?.contentModificationDate ?? .distantPast,
            contents: text
        )
    }
}

@MainActor
final class VideoBoxModel: ObservableObject {
    static let preset = "Very Fast 1080p30"

    @Published private(set) var jobs: [ConversionJob] = [] {
        didSet { updateSystemProgress() }
    }
    @Published private(set) var isConverting = false {
        didSet { updateSystemProgress() }
    }
    @Published var isDropTargeted = false
    @Published var lastMessage: String?
    @Published private(set) var logEntries: [LogEntry] = []
    @Published var isLogsWindowOpen = false
    @Published var selectedLogID: URL?

    private var currentProcess: Process?
    private var currentJobID: UUID?
    private var cancellationRequested = false

    private let fileManager = FileManager.default
    private let supportedExtensions: Set<String> = [
        "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ts", "webm", "wmv"
    ]

    var readyCount: Int {
        jobs.filter { $0.status == .ready }.count
    }

    var completedCount: Int {
        jobs.filter { [.done, .skipped].contains($0.status) }.count
    }

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        return jobs.map(\.progress).reduce(0, +) / Double(jobs.count)
    }

    /// The ordinal of the job currently being processed, not the number of
    /// completed jobs. For example, the second active job in a seven-file
    /// queue is displayed as 2/7.
    var taskProgressText: String {
        guard !jobs.isEmpty else { return "" }

        if let runningIndex = jobs.firstIndex(where: { $0.status == .running }) {
            return "\(runningIndex + 1)/\(jobs.count)"
        }

        if isConverting,
           let nextIndex = jobs.firstIndex(where: { $0.status == .ready || $0.status == .waiting }) {
            return "\(nextIndex + 1)/\(jobs.count)"
        }

        if completedCount == jobs.count {
            return "\(jobs.count)/\(jobs.count)"
        }

        return "0/\(jobs.count)"
    }

    var windowTitle: String {
        taskProgressText.isEmpty ? AppIdentity.name : "\(AppIdentity.name) — \(taskProgressText)"
    }

    var progressLabel: String {
        if isConverting, let job = jobs.first(where: { $0.status == .running }) {
            return "Converting \(job.inputURL.lastPathComponent)"
        }
        if !jobs.isEmpty, completedCount == jobs.count {
            return "All conversions complete"
        }
        if jobs.isEmpty {
            return "Drop videos to begin"
        }
        return "Ready to convert"
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add Videos"

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.add(urls: panel.urls)
            }
        }
    }

    func acceptDrop(providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(fileURLType) }) else {
            return false
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(fileURLType) {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { [weak self] item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                guard let url else { return }
                Task { @MainActor in
                    self?.add(urls: [url])
                }
            }
        }

        return true
    }

    func add(urls: [URL]) {
        var added = 0
        let existingPaths = Set(jobs.map { $0.inputURL.standardizedFileURL.path })

        for url in urls {
            let normalizedURL = url.standardizedFileURL
            guard isSupportedVideo(normalizedURL),
                  !fileManager.directoryExists(at: normalizedURL),
                  !existingPaths.contains(normalizedURL.path),
                  !jobs.contains(where: { $0.inputURL.standardizedFileURL.path == normalizedURL.path }) else {
                continue
            }

            let stem = normalizedURL.deletingPathExtension().lastPathComponent
            guard !stem.lowercased().hasSuffix("-decoded") else { continue }

            let outputURL = normalizedURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(stem)-decoded.mp4")

            jobs.append(
                ConversionJob(
                    id: UUID(),
                    inputURL: normalizedURL,
                    outputURL: outputURL,
                    fileSize: fileSize(at: normalizedURL)
                )
            )
            added += 1
        }

        if added > 0 {
            lastMessage = nil
        } else if !urls.isEmpty {
            lastMessage = "No new supported video files were added."
        }
    }

    func remove(jobID: UUID) {
        guard !jobs.contains(where: { $0.id == jobID && $0.status == .running }) else { return }
        jobs.removeAll { $0.id == jobID }
    }

    func clearAll() {
        guard !isConverting else { return }
        jobs.removeAll()
        lastMessage = nil
    }

    func showLogs() {
        loadLogs()
        isLogsWindowOpen = true
    }

    /// Rereads the log folder and keeps the newest entry selected.
    func loadLogs() {
        let entries = ConversionLog.entries()
        logEntries = entries
        if selectedLogID == nil || !entries.contains(where: { $0.id == selectedLogID }) {
            selectedLogID = entries.first?.id
        }
    }

    func start() {
        guard !isConverting else { return }
        guard readyCount > 0 else {
            lastMessage = "Add at least one video before converting."
            return
        }
        guard resolveHandBrakeCLI() != nil else {
            lastMessage = "HandBrakeCLI is not bundled yet. Add it to the app’s Resources folder and try again."
            return
        }

        lastMessage = nil
        cancellationRequested = false
        isConverting = true
        runNextJob()
    }

    func cancel() {
        guard isConverting else { return }
        cancellationRequested = true
        currentProcess?.terminate()
    }

    private func fileSize(at url: URL) -> Int64? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64
    }

    private func runNextJob() {
        guard let index = jobs.firstIndex(where: { $0.status == .ready || $0.status == .waiting }) else {
            isConverting = false
            currentProcess = nil
            currentJobID = nil
            return
        }

        for jobIndex in jobs.indices where jobs[jobIndex].status == .ready {
            jobs[jobIndex].status = .waiting
        }

        let job = jobs[index]
        if fileManager.fileExists(atPath: job.outputURL.path) {
            jobs[index].status = .skipped
            jobs[index].progress = 1
            jobs[index].detail = "Output already exists"
            runNextJob()
            return
        }

        guard let executableURL = resolveHandBrakeCLI() else {
            finish(jobID: job.id, exitStatus: -1, error: "HandBrakeCLI is not bundled.")
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "-i", job.inputURL.path,
            "-o", job.outputURL.path,
            "-Z", Self.preset,
            "--json"
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.consume(output: text, for: job.id)
            }
        }

        process.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.finish(jobID: job.id, exitStatus: process.terminationStatus, error: nil)
            }
        }

        jobs[index].status = .running
        jobs[index].detail = "Starting HandBrake"
        currentJobID = job.id
        currentProcess = process

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            finish(jobID: job.id, exitStatus: -1, error: error.localizedDescription)
        }
    }

    private func consume(output: String, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].logOutput.append(output)

        if let progress = extractProgress(from: output) {
            jobs[index].progress = min(max(progress, 0), 1)
        }

        let lastLine = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if let lastLine {
            jobs[index].detail = String(lastLine.prefix(100))
        }
    }

    private func finish(jobID: UUID, exitStatus: Int32, error: String?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].exitStatus = exitStatus
        jobs[index].finishedAt = Date()
        currentProcess = nil
        currentJobID = nil

        if cancellationRequested {
            jobs[index].status = .failed
            jobs[index].errorMessage = "Cancelled"
            jobs[index].detail = "Cancelled"
            cancellationRequested = false
            for jobIndex in jobs.indices where jobs[jobIndex].status == .waiting {
                jobs[jobIndex].status = .ready
            }
            isConverting = false
            lastMessage = "Conversion cancelled."
            return
        }

        if exitStatus == 0, fileManager.fileExists(atPath: jobs[index].outputURL.path) {
            jobs[index].status = .done
            jobs[index].progress = 1
            jobs[index].detail = "Saved next to original"
            jobs[index].outputSize = fileSize(at: jobs[index].outputURL)
        } else {
            jobs[index].status = .failed
            jobs[index].errorMessage = error ?? "HandBrake exited with status \(exitStatus)."
            jobs[index].detail = jobs[index].errorMessage ?? "Conversion failed"
        }

        // Keep the full output for successful jobs too: the log file records
        // the compressed size, which is the point of writing one.
        if let logURL = ConversionLog.write(for: jobs[index]) {
            jobs[index].logURL = logURL
        } else {
            lastMessage = "Could not save the log for \(jobs[index].inputURL.lastPathComponent)."
        }
        loadLogs()

        runNextJob()
    }

    private func extractProgress(from output: String) -> Double? {
        let patterns = [
            #"\"Progress\"\s*:\s*([0-9]*\.?[0-9]+)"#,
            #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            guard let match = expression.firstMatch(in: output, range: range), match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: output),
                  let value = Double(output[valueRange]) else { continue }
            return value > 1 ? value / 100 : value
        }

        return nil
    }

    private func isSupportedVideo(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func resolveHandBrakeCLI() -> URL? {
        var candidates: [URL] = []

        if let configuredPath = ProcessInfo.processInfo.environment["VIDEOBOX_HANDBRAKE_CLI"], !configuredPath.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }

        if let bundledURL = Bundle.main.url(forResource: "HandBrakeCLI", withExtension: nil) {
            candidates.append(bundledURL)
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/HandBrakeCLI"),
            URL(fileURLWithPath: "/usr/local/bin/HandBrakeCLI")
        ])

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func updateSystemProgress() {
        guard NSApp != nil else { return }

        let progressText = taskProgressText
        NSApp.dockTile.badgeLabel = progressText.isEmpty ? nil : progressText
        NSApp.dockTile.display()

        for window in NSApp.windows where !(window is NSPanel) {
            window.title = windowTitle
        }
    }
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

struct ContentView: View {
    @ObservedObject var model: VideoBoxModel
    let appDelegate: VideoBoxAppDelegate
    @Environment(\.openWindow) private var openWindow
    private let panelHeight: CGFloat = 224

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                intro
                topControls
                HStack(alignment: .top, spacing: 12) {
                    dropPanel
                    queuePanel
                }
                footer
                if let message = model.lastMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            model.acceptDrop(providers: providers)
        }
        .navigationTitle(model.windowTitle)
        .sheet(isPresented: $model.isLogsWindowOpen) {
            ConversionLogsWindow(model: model)
        }
        .onAppear {
            model.loadLogs()
            let action = openWindow
            appDelegate.reopenMainWindow = {
                action(id: "main")
            }
        }
    }

    private var intro: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppIdentity.name)
                    .font(.system(size: 24, weight: .semibold))
                Text("Batch convert videos locally. Originals stay untouched.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("HandBrake engine · local only")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            SettingCell(label: "Preset", value: VideoBoxModel.preset)
                .frame(maxWidth: .infinity)
            SettingCell(label: "Output", value: "Same folder · .mp4")
                .frame(maxWidth: .infinity)
            SettingCell(label: "Existing output", value: "Skip, never overwrite")
                .frame(maxWidth: .infinity)

            if model.isConverting {
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.bordered)
            }

            Button(model.isConverting ? "Converting…" : "Convert \(model.readyCount) video\(model.readyCount == 1 ? "" : "s")") {
                model.start()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isConverting || model.readyCount == 0)
        }
    }

    private var dropPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionLabel("INPUT")
                Spacer()
                Button("Add files") { model.chooseFiles() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            VStack(spacing: 9) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tint)
                Text("Drop videos here")
                    .font(.headline)
                Text("Multiple files supported · files stay in their original folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 132)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        model.isDropTargeted ? Color.accentColor : Color.accentColor.opacity(0.7),
                        style: StrokeStyle(lineWidth: model.isDropTargeted ? 2 : 1, dash: [6])
                    )
            }

            Text("Folders and generated -decoded files are skipped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                Button {
                    model.showLogs()
                } label: {
                    Label("Logs \(model.logEntries.count)", systemImage: "doc.text.magnifyingglass")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show conversion logs, newest first")
                .accessibilityLabel("Show conversion logs, newest first")
                Button {
                    model.clearAll()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(model.jobs.isEmpty || model.isConverting)
                .help("Clear all queued videos")
                Text("\(model.jobs.count) video\(model.jobs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.jobs.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No videos queued")
                        .font(.headline)
                    Text("Drop files into the input area to create a batch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, minHeight: 145)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            QueueRow(
                                job: job,
                                remove: { model.remove(jobID: job.id) }
                            )
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 145, maxHeight: 240)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.completedCount) / \(model.jobs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: model.overallProgress)
                .progressViewStyle(.linear)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

struct QueueRow: View {
    let job: ConversionJob
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(job.fileType)
                    .font(.caption2.weight(.medium))
                    .frame(width: 34, height: 34)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.inputURL.lastPathComponent)
                        .lineLimit(1)
                    Text("\(formattedSize(job.fileSize))  →  \(job.outputURL.lastPathComponent)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                StatusText(status: job.status)

                if job.status != .running {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove from queue")
                }
            }

            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(job.status == .done ? .green : .accentColor)

            if !job.detail.isEmpty {
                Text(job.detail)
                    .font(.caption2)
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
    }

    private func formattedSize(_ size: Int64?) -> String {
        guard let size else { return "Size unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// One window listing every log on disk, newest first.
private struct ConversionLogsWindow: View {
    @ObservedObject var model: VideoBoxModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversion Logs")
                    .font(.title2.weight(.semibold))
                Text("\(model.logEntries.count) file\(model.logEntries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.loadLogs() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if model.logEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No logs yet")
                        .font(.headline)
                    Text("A log file is written every time a conversion finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 300)
                    Divider()
                    detail
                }
            }

            HStack {
                Button("Open Logs Folder") {
                    NSWorkspace.shared.open(ConversionLog.directory)
                }
                Spacer()
                if let entry = selected {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.id])
                    }
                    Button("Open Log") {
                        NSWorkspace.shared.open(entry.id)
                    }
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(entry.contents, forType: .string)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 900, height: 600)
    }

    private var selected: LogEntry? {
        model.logEntries.first { $0.id == model.selectedLogID }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.logEntries) { entry in
                    Button {
                        model.selectedLogID = entry.id
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.isSuccess ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text("\(entry.finished)  ·  \(entry.inputSize) → \(entry.outputSize)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            entry.id == model.selectedLogID
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selected {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.result)
                        .font(.caption.weight(.medium))
                    Text(entry.id.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ScrollView {
                    Text(entry.contents)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.leading, 14)
        } else {
            Text("Select a log")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StatusText: View {
    let status: ConversionStatus

    var body: some View {
        Text(status.label)
            .font(.caption2)
            .foregroundStyle(color)
            .frame(minWidth: 58, alignment: .trailing)
    }

    private var color: Color {
        switch status {
        case .done: .green
        case .failed: .red
        case .running: .accentColor
        case .ready, .waiting, .skipped: .secondary
        }
    }
}

struct SettingCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor))
        }
    }
}

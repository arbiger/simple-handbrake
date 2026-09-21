import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct VideoBoxApp: App {
    @NSApplicationDelegateAdaptor(VideoBoxAppDelegate.self) private var appDelegate
    private let model = VideoBoxModel()

    var body: some Scene {
        WindowGroup("Video Box", id: "main") {
            ContentView(model: model, appDelegate: appDelegate)
                .frame(minWidth: 820, minHeight: 640)
        }
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

    var fileType: String {
        let value = inputURL.pathExtension.uppercased()
        return value.isEmpty ? "FILE" : value
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
        taskProgressText.isEmpty ? "Video Box" : "Video Box — \(taskProgressText)"
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

            let attributes = try? fileManager.attributesOfItem(atPath: normalizedURL.path)
            let fileSize = attributes?[.size] as? Int64

            jobs.append(
                ConversionJob(
                    id: UUID(),
                    inputURL: normalizedURL,
                    outputURL: outputURL,
                    fileSize: fileSize
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
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
        } else {
            jobs[index].status = .failed
            jobs[index].errorMessage = error ?? "HandBrake exited with status \(exitStatus)."
            jobs[index].detail = jobs[index].errorMessage ?? "Conversion failed"
        }

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

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    HStack(alignment: .top, spacing: 18) {
                        dropPanel
                            .frame(maxWidth: .infinity)
                        queuePanel
                            .frame(maxWidth: .infinity)
                    }
                    settingsRow
                    footer
                    if let message = model.lastMessage {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            model.acceptDrop(providers: providers)
        }
        .navigationTitle(model.windowTitle)
        .onAppear {
            let action = openWindow
            appDelegate.reopenMainWindow = {
                action(id: "main")
            }
        }
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            appBrandMark
            VStack(alignment: .leading, spacing: 1) {
                Text("Video Box")
                    .font(.headline)
                Text("Simple local video conversion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("HandBrake engine · local only")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .background(.bar)
    }

    private var appBrandMark: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "play.rectangle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Convert videos")
                .font(.system(size: 25, weight: .medium))
            Text("Drop one or more videos below. We’ll keep the originals and create converted MP4 files beside them.")
                .foregroundStyle(.secondary)
        }
    }

    private var dropPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("INPUT")
                Spacer()
                Button("Add files") { model.chooseFiles() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tint)
                Text("Drop videos here")
                    .font(.headline)
                Text("Multiple files supported · files stay in their original folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose files") { model.chooseFiles() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(18)
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
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                Text("\(model.jobs.count) video\(model.jobs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No videos queued")
                        .font(.headline)
                    Text("Drop files into the input area to create a batch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, minHeight: 230)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            QueueRow(job: job) {
                                model.remove(jobID: job.id)
                            }
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 230, maxHeight: 300)
            }
        }
        .padding(18)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        }
    }

    private var settingsRow: some View {
        HStack(spacing: 10) {
            SettingCell(label: "Preset", value: VideoBoxModel.preset)
            SettingCell(label: "Output", value: "Same folder · .mp4")
            SettingCell(label: "Existing output", value: "Skip, never overwrite")
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 16) {
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

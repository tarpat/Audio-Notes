import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct LectureRecorderApp: App {
    @StateObject private var library = LectureLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 900, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class AudioPlayback: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if let player, player.url == url {
            if player.isPlaying { player.pause() } else { player.play() }
            isPlaying = player.isPlaying
            return
        }
        stop()
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.prepareToPlay()
            next.play()
            player = next
            duration = next.duration
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateTime() }
            }
        } catch { }
    }

    func seek(_ time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        isPlaying = false; currentTime = 0; duration = 0
    }

    private func updateTime() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying && currentTime >= duration { stop() }
    }
}

struct Lecture: Identifiable, Hashable {
    let id: URL
    let course: String
    var title: String { displayFolderName.base }
    var takeNumber: Int? { displayFolderName.take }
    private var displayFolderName: (base: String, take: Int?) {
        let folderName = id.lastPathComponent
        guard let range = folderName.range(of: #" \((\d+)\)$"#, options: .regularExpression),
              let take = Int(folderName[range].filter(\.isNumber)) else { return (folderName, nil) }
        let base = String(folderName[..<range.lowerBound])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yyyy h:mma"
        return formatter.date(from: base) == nil ? (folderName, nil) : (base, take)
    }
    var audioURL: URL { id.appendingPathComponent("recording.m4a") }
    var transcriptURL: URL { id.appendingPathComponent("transcript.md") }
    var notesURL: URL { id.appendingPathComponent("notes.md") }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }
    var hasNotes: Bool { FileManager.default.fileExists(atPath: notesURL.path) }
    var duration: TimeInterval {
        guard let asset = try? AVAudioPlayer(contentsOf: audioURL) else { return 0 }
        return asset.duration
    }
    var status: String { hasNotes ? "Notes ready" : hasTranscript ? "Transcript ready" : "Recorded" }
}

@MainActor
final class LectureLibrary: ObservableObject {
    @Published var lectures: [Lecture] = []
    @Published var courses: [String] = ["Uncategorized"]
    @Published var selectedID: URL?
    @Published var selectedCourse = UserDefaults.standard.string(forKey: "selectedCourse") ?? "Uncategorized"
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isWorking = false
    @Published var progress = ""
    @Published var workProgress: Double = 0
    @Published var error: String?
    @Published var title = LectureLibrary.defaultTitle()
    private var suggestedTitle = LectureLibrary.defaultTitle()
    @Published var model = UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3.5:4b"
    @Published var whisperModelPath = UserDefaults.standard.string(forKey: "whisperModelPath") ?? ""
    @Published var recordingsPath = UserDefaults.standard.string(forKey: "recordingsPath") ??
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/LectureRecorder").path
    @Published var transcriptText = ""
    @Published var notesText = ""

    private var recorder: AVAudioRecorder?

    init() { refresh() }

    var selected: Lecture? { lectures.first { $0.id == selectedID } }
    var visibleLectures: [Lecture] { lectures.filter { $0.course == selectedCourse } }

    nonisolated private static func defaultTitle(for date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yyyy h:mma"
        return formatter.string(from: date).lowercased()
    }

    func refresh() {
        let root = URL(fileURLWithPath: recordingsPath, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [Lecture] = []
        var foundCourses = ["Uncategorized"]
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if FileManager.default.fileExists(atPath: entry.appendingPathComponent("recording.m4a").path) {
                found.append(Lecture(id: entry, course: "Uncategorized"))
                continue
            }
            let course = entry.lastPathComponent
            foundCourses.append(course)
            let lecturesInCourse = (try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            found += lecturesInCourse.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("recording.m4a").path)
            }.map { Lecture(id: $0, course: course) }
        }
        courses = Array(Set(foundCourses)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        lectures = found.sorted { $0.id.lastPathComponent > $1.id.lastPathComponent }
        if !courses.contains(selectedCourse) {
            selectedCourse = courses.first ?? "Uncategorized"
            UserDefaults.standard.set(selectedCourse, forKey: "selectedCourse")
        }
        if selectedID == nil || !lectures.contains(where: { $0.id == selectedID }) {
            selectedID = visibleLectures.first?.id
        }
        loadSelected()
    }

    func select(_ lecture: Lecture) { selectedID = lecture.id; loadSelected() }

    func selectCourse(_ course: String) {
        selectedCourse = course
        UserDefaults.standard.set(course, forKey: "selectedCourse")
        selectedID = visibleLectures.first?.id
        loadSelected()
    }

    func addCourse(_ name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !cleanName.isEmpty, cleanName != ".", cleanName != ".." else { return }
        do {
            let folder = URL(fileURLWithPath: recordingsPath, isDirectory: true).appendingPathComponent(cleanName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            selectedCourse = cleanName
            UserDefaults.standard.set(cleanName, forKey: "selectedCourse")
            selectedID = nil
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func loadSelected() {
        transcriptText = selected.flatMap { try? String(contentsOf: $0.transcriptURL, encoding: .utf8) } ?? ""
        notesText = selected.flatMap { try? String(contentsOf: $0.notesURL, encoding: .utf8) } ?? ""
    }

    func startRecording() {
        do {
            let root = URL(fileURLWithPath: recordingsPath, isDirectory: true)
            let now = Date.now
            let timestamp = Self.defaultTitle(for: now)
            let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle = enteredTitle.isEmpty || enteredTitle == suggestedTitle ? timestamp : enteredTitle
            let folderName = cleanTitle
            let courseRoot = root.appendingPathComponent(selectedCourse, isDirectory: true)
            try FileManager.default.createDirectory(at: courseRoot, withIntermediateDirectories: true)
            var folder = courseRoot.appendingPathComponent(folderName, isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = courseRoot.appendingPathComponent("\(folderName) (\(suffix))", isDirectory: true)
                suffix += 1
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let audioURL = folder.appendingPathComponent("recording.m4a")
            let newRecorder = try AVAudioRecorder(url: audioURL, settings: settings)
            newRecorder.isMeteringEnabled = false
            guard newRecorder.record() else { throw AppError.recordingStart }
            recorder = newRecorder
            isRecording = true
            isPaused = false
            suggestedTitle = Self.defaultTitle()
            title = suggestedTitle
            selectedID = folder
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func togglePause() {
        if isPaused { recorder?.record() } else { recorder?.pause() }
        isPaused.toggle()
    }

    func stopRecording() {
        recorder?.stop(); recorder = nil
        isRecording = false; isPaused = false
        refresh()
    }

    func deleteSelectedLecture() {
        guard let lecture = selected, !isRecording, !isWorking else { return }
        do {
            try FileManager.default.removeItem(at: lecture.id)
            selectedID = nil
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func renameSelectedLecture(to name: String) {
        guard let lecture = selected else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !cleanName.isEmpty, cleanName != ".", cleanName != ".." else { return }
        if cleanName == lecture.title { return }
        let destination = lecture.id.deletingLastPathComponent().appendingPathComponent(cleanName, isDirectory: true)
        guard destination != lecture.id else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "A lecture with that name already exists in this course."; return
        }
        do {
            try FileManager.default.moveItem(at: lecture.id, to: destination)
            selectedID = destination
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func transcribe() {
        guard let lecture = selected else { return }
        guard !whisperModelPath.isEmpty, FileManager.default.fileExists(atPath: whisperModelPath) else {
            error = "Choose a local Whisper model file in Settings first."; return
        }
        guard let executable = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "whisper-cli is not installed. Install whisper.cpp, then try again."; return
        }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "ffmpeg is not installed. Install it to convert the recording for transcription."; return
        }
        isWorking = true; progress = "Transcribing audio locally"; workProgress = 0
        let modelPath = whisperModelPath
        Task {
            do {
                let text = try await Task.detached(priority: .utility) {
                    try Self.runWhisper(executable: executable, ffmpeg: ffmpeg, model: modelPath, audio: lecture.audioURL)
                }.value
                try text.write(to: lecture.transcriptURL, atomically: true, encoding: .utf8)
                refresh()
            } catch { self.error = error.localizedDescription }
            isWorking = false; progress = ""; workProgress = 0
        }
    }

    nonisolated private static func runWhisper(executable: String, ffmpeg: String, model: String, audio: URL) throws -> String {
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: ffmpeg)
        convert.arguments = ["-nostdin", "-y", "-i", audio.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path]
        convert.standardError = FileHandle.nullDevice
        convert.standardOutput = FileHandle.nullDevice
        try convert.run(); convert.waitUntilExit()
        guard convert.terminationStatus == 0 else { throw AppError.audioConversionFailed }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-\(UUID().uuidString)")
        process.arguments = ["-m", model, "-f", wavURL.path, "-otxt", "-of", output.path]
        defer { try? FileManager.default.removeItem(atPath: output.path + ".txt") }
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppError.whisperFailed }
        let transcriptURL = URL(fileURLWithPath: output.path + ".txt")
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8), !text.isEmpty else { throw AppError.emptyTranscript }
        return text
    }

    func generateNotes() {
        guard let lecture = selected, lecture.hasTranscript else { error = "Transcribe this lecture first."; return }
        guard let transcript = try? String(contentsOf: lecture.transcriptURL, encoding: .utf8) else { error = "Could not read the transcript."; return }
        isWorking = true; progress = "Preparing notes"; workProgress = 0.05
        UserDefaults.standard.set(model, forKey: "ollamaModel")
        Task {
            do {
                let notes = try await self.askOllama(model: model, transcript: transcript) { message, fraction in
                    self.progress = message
                    self.workProgress = fraction
                }
                try notes.write(to: lecture.notesURL, atomically: true, encoding: .utf8)
                refresh()
            } catch { self.error = error.localizedDescription }
            isWorking = false; progress = ""; workProgress = 0
        }
    }

    private func askOllama(model: String, transcript: String, update: @escaping @MainActor (String, Double) -> Void) async throws -> String {
        let chunks = transcript.split(into: 7_000)
        var summaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            update(chunks.count > 1 ? "Summarizing section \(index + 1) of \(chunks.count)" : "Writing structured notes", 0.1 + 0.78 * Double(index) / Double(chunks.count))
            let instruction = chunks.count == 1
                ? "Create clear, faithful lecture notes with a descriptive title, headings, concise bullet points, key terms and a short recap. Format as valid Markdown. Put every heading, numbered section, and bullet on its own line, with a blank line between sections. Never run a heading or label into the preceding sentence. Do not invent information; mark unclear fragments as uncertain."
                : "Summarize this lecture segment as structured notes in valid Markdown. Put every heading, numbered section, and bullet on its own line, with a blank line between sections. Preserve key facts, terms and examples; do not invent information. This is segment \(index + 1) of \(chunks.count)."
            summaries.append(try await Self.chat(model: model, prompt: "\(instruction)\n\nTRANSCRIPT:\n\(chunk)"))
        }
        if summaries.count == 1 { return summaries[0] }
        update("Combining sections into final notes", 0.9)
        return try await Self.chat(model: model, prompt: "Combine these sequential lecture segment notes into one coherent set of notes. Remove repetition, preserve useful detail, add a descriptive title and short recap. Do not add facts.\n\n\(summaries.joined(separator: "\n\n---\n\n"))")
    }

    private static func chat(model: String, prompt: String) async throws -> String {
        let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
        var request = URLRequest(url: endpoint, timeoutInterval: 1800)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": prompt]], "stream": false, "options": ["num_ctx": 8192]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppError.ollamaUnavailable }
        return try JSONDecoder().decode(OllamaResponse.self, from: data).message.content
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: recordingsPath)
        if panel.runModal() == .OK, let url = panel.url {
            recordingsPath = url.path; UserDefaults.standard.set(url.path, forKey: "recordingsPath"); refresh()
        }
    }

    func chooseWhisperModel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            whisperModelPath = url.path; UserDefaults.standard.set(url.path, forKey: "whisperModelPath")
        }
    }
}

struct OllamaResponse: Decodable { let message: Message; struct Message: Decodable { let content: String } }

enum AppError: LocalizedError {
    case recordingStart, audioConversionFailed, whisperFailed, emptyTranscript, ollamaUnavailable
    var errorDescription: String? {
        switch self {
        case .recordingStart: "Could not start recording. Check microphone access."
        case .audioConversionFailed: "Could not convert this recording for Whisper. Check that the audio file is valid."
        case .whisperFailed: "Whisper could not transcribe this recording. Check the model and audio format."
        case .emptyTranscript: "Whisper finished without producing a transcript."
        case .ollamaUnavailable: "Could not reach the selected Ollama model. Check that Ollama is running and the model is installed."
        }
    }
}

struct ContentView: View {
    @ObservedObject var library: LectureLibrary
    @State private var tab = 0
    @State private var showingAddCourse = false
    @State private var newCourseName = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var sidebarVisible = true
    @StateObject private var playback = AudioPlayback()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if sidebarVisible {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.circle.fill").font(.system(size: 28)).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Lecture Recorder").font(.headline)
                                Text("Your recordings, kept local").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel(sidebarVisible ? "Collapse sidebar" : "Expand sidebar")
                        .help(sidebarVisible ? "Collapse sidebar" : "Expand sidebar")
                        .buttonStyle(.plain)
                }.padding(.bottom, 8)
                Button { tab = 0 } label: {
                    if sidebarVisible { Label("Lectures", systemImage: "waveform") }
                    else { Image(systemName: "waveform").frame(maxWidth: .infinity) }
                }
                    .buttonStyle(.plain).foregroundStyle(tab == 0 ? .blue : .primary)
                    .accessibilityLabel("Lectures").help("Lectures")
                Button { tab = 1 } label: {
                    if sidebarVisible { Label("Settings", systemImage: "gearshape") }
                    else { Image(systemName: "gearshape").frame(maxWidth: .infinity) }
                }
                    .buttonStyle(.plain).foregroundStyle(tab == 1 ? .blue : .primary)
                    .accessibilityLabel("Settings").help("Settings")
                Spacer()
                if sidebarVisible { Text("LOCAL PROCESSING").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            }
            .padding(sidebarVisible ? 20 : 10).frame(width: sidebarVisible ? 210 : 58).background(Color(nsColor: .underPageBackgroundColor))

            if tab == 0 { lecturesView } else { settingsView }
        }
        .alert("Lecture Recorder", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .sheet(isPresented: $showingAddCourse) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add course folder").font(.headline)
                TextField("Course name", text: $newCourseName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showingAddCourse = false }
                    Button("Add Course") {
                        library.addCourse(newCourseName)
                        newCourseName = ""
                        showingAddCourse = false
                    }.buttonStyle(.borderedProminent).disabled(newCourseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(22).frame(width: 340)
        }
        .confirmationDialog("Delete this lecture?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Lecture", role: .destructive) { library.deleteSelectedLecture() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the recording, transcript, and notes.")
        }
        .sheet(isPresented: $showingRename) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename lecture").font(.headline)
                TextField("Lecture name", text: $renameText).textFieldStyle(.roundedBorder)
                    .onSubmit { library.renameSelectedLecture(to: renameText); showingRename = false }
                HStack {
                    Spacer()
                    Button("Cancel") { showingRename = false }
                    Button("Save") { library.renameSelectedLecture(to: renameText); showingRename = false }
                        .buttonStyle(.borderedProminent)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(22).frame(width: 380)
        }
    }

    private var lecturesView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("Lectures").font(.title2.bold())
                    Spacer()
                    Button { newCourseName = ""; showingAddCourse = true } label: { Label("Add Course", systemImage: "folder.badge.plus") }
                        .buttonStyle(.bordered)
                }
                HStack(spacing: 10) {
                    Picker("Course", selection: Binding(get: { library.selectedCourse }, set: { library.selectCourse($0) })) {
                        ForEach(library.courses, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 180)
                    if !library.isRecording {
                        TextField("Recording title", text: $library.title).textFieldStyle(.roundedBorder)
                        Button { library.startRecording() } label: { Label("Record", systemImage: "record.circle") }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }.padding(20)
            Divider()
            if library.visibleLectures.isEmpty {
                ContentUnavailableView("No recordings in \(library.selectedCourse)", systemImage: "waveform", description: Text("Record a lecture here or choose another course."))
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(get: { library.selectedID }, set: { id in
                        if let id, let lecture = library.visibleLectures.first(where: { $0.id == id }) { library.select(lecture) }
                    })) {
                        ForEach(library.visibleLectures) { lecture in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(lecture.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                HStack {
                                    Text(lecture.takeNumber.map { "\(lecture.status) · Take \($0)" } ?? lecture.status)
                                    Spacer()
                                    Text(lecture.duration.formattedDuration)
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(lecture.id)
                        }
                    }.listStyle(.sidebar).frame(minWidth: 170, idealWidth: 190, maxWidth: 210)
                    Divider()
                    detailView.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if library.isRecording {
                HStack {
                    Circle().fill(library.isPaused ? .orange : .red).frame(width: 9, height: 9)
                    Text(library.isPaused ? "Recording paused" : "Recording lecture")
                    Spacer()
                    Button(library.isPaused ? "Resume" : "Pause") { library.togglePause() }
                    Button("Stop") { library.stopRecording() }.buttonStyle(.borderedProminent)
                }.padding(14).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)).padding()
            }
        }
    }

    @ViewBuilder private var detailView: some View {
        if let lecture = library.selected {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lecture.title).font(.title3.bold()).lineLimit(2)
                        Text(lecture.course).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { renameText = lecture.title; showingRename = true } label: {
                        Label("Rename", systemImage: "pencil")
                    }.accessibilityLabel("Rename").buttonStyle(.bordered).disabled(library.isRecording || library.isWorking)
                    Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                        Label("Delete", systemImage: "trash")
                    }.buttonStyle(.bordered)
                        .disabled(library.isRecording || library.isWorking)
                }
                Text("\(lecture.duration.formattedDuration) · \(lecture.status)" + (lecture.takeNumber.map { " · Take \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { playback.toggle(lecture.audioURL) } label: {
                        Label(playback.isPlaying ? "Pause audio" : "Play audio", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([lecture.id]) } label: { Label("Show in Finder", systemImage: "folder") }
                }.buttonStyle(.bordered)
                if playback.duration > 0 {
                    HStack(spacing: 10) {
                        Text(playback.currentTime.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek($0) }), in: 0...max(playback.duration, 0.1))
                        Text(playback.duration.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack {
                    Text("Transcript").font(.headline)
                    Spacer()
                    Button("Transcribe") { library.transcribe() }.disabled(library.isWorking || !lecture.hasTranscript && library.isRecording)
                }
                ScrollView { Text(library.transcriptText.isEmpty ? "Your transcript will appear here." : library.transcriptText)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).font(.body).lineSpacing(4) }
                    .frame(maxHeight: .infinity).layoutPriority(1).padding(14).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("Notes").font(.headline)
                    Spacer()
                    Picker("Model", selection: $library.model) {
                        Text("Qwen 3.5 4B").tag("qwen3.5:4b")
                        Text("Qwen 3.5 9B").tag("qwen3.5:9b")
                    }.labelsHidden().frame(width: 160)
                    Button(lecture.hasNotes ? "Regenerate Notes" : "Generate Notes") { library.generateNotes() }
                        .disabled(library.isWorking || !lecture.hasTranscript)
                }
                if !library.notesText.isEmpty {
                    ScrollView {
                        Text((try? AttributedString(markdown: library.notesText.readableMarkdown)) ?? AttributedString(library.notesText.readableMarkdown))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).lineSpacing(4)
                    }
                        .frame(maxHeight: .infinity).layoutPriority(1).padding(14).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Generate notes from the transcript with your chosen Ollama model.").font(.caption).foregroundStyle(.secondary)
                }
                if library.isWorking {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: library.progress.contains("Transcrib") ? "waveform" : "sparkles").foregroundStyle(.blue)
                            Text(library.progress).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if library.workProgress > 0 { Text("\(Int(library.workProgress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        if library.workProgress > 0 {
                            ProgressView(value: library.workProgress).progressViewStyle(.linear).tint(.blue)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(.blue)
                        }
                    }.padding(10).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.padding(20)
        } else {
            ContentUnavailableView("Select a lecture", systemImage: "text.book.closed")
        }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Settings").font(.title2.bold())
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Recordings folder").font(.headline)
                HStack { Text(library.recordingsPath).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer(); Button("Choose…") { library.chooseRecordingsFolder() } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Transcription").font(.headline)
                Text("Uses local whisper.cpp and FFmpeg. Install both, then select a Whisper model file to enable transcription.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Text(library.whisperModelPath.isEmpty ? "No Whisper model selected" : URL(fileURLWithPath: library.whisperModelPath).lastPathComponent).font(.caption).lineLimit(1); Spacer(); Button("Choose model…") { library.chooseWhisperModel() } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes").font(.headline)
                Text("Ollama runs locally at 127.0.0.1:11434. Available model: Qwen 3.5 4B.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let seconds = Int(self)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension String {
    var readableMarkdown: String {
        var value = replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: #"^Lecture Notes:\s*"#, with: "# ", options: .regularExpression)
        let sections = [
            "Overview of Misclassifications", "Defining False Positives and Negatives",
            "Classification Transitions", "Key Terms", "Recap"
        ]
        for section in sections {
            value = value.replacingOccurrences(of: #"(?<!## )(?:\d+\.\s*)?"# + NSRegularExpression.escapedPattern(for: section),
                                               with: "\n\n## " + section + "\n\n", options: .regularExpression)
        }
        let labels = [
            "Context", "General Term", "False Positive Definition", "False Negative Definition",
            "Example from transcript", "Correction Logic", "Introduction of New Concepts", "Quote",
            "Status", "False Positive", "False Negative", "Misclassification", "Note"
        ].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        value = value.replacingOccurrences(of: #"(?<!- )\*{0,2}("# + labels + #")\*{0,2}:\s*"#,
                                           with: "\n- **$1:** ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?<!\n)(?=\*\s{1,3})"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return value
    }

    func split(into maxCharacters: Int) -> [String] {
        guard count > maxCharacters else { return [self] }
        var chunks: [String] = []
        var current = ""
        for paragraph in components(separatedBy: .newlines) {
            if current.count + paragraph.count > maxCharacters, !current.isEmpty {
                chunks.append(current); current = ""
            }
            if paragraph.count > maxCharacters {
                if !current.isEmpty { chunks.append(current); current = "" }
                var remainder = paragraph[...]
                while remainder.count > maxCharacters {
                    let end = remainder.index(remainder.startIndex, offsetBy: maxCharacters)
                    chunks.append(String(remainder[..<end])); remainder = remainder[end...]
                }
                current += remainder
            } else {
                if !current.isEmpty { current += "\n" }
                current += paragraph
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

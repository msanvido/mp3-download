import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle
        case recording
        case waitingForAudio
        case error(String)
    }

    @Published var status: Status = .idle
    @Published var outputDirectory: URL
    @Published var currentTrackTitle: String = ""
    @Published var currentLevelDB: Float = -120
    @Published var elapsedSeconds: Double = 0
    @Published var completedFiles: [URL] = []
    @Published var silenceSplitSeconds: Double = 0.5
    @Published var streamEndSeconds: Double = 25.0
    @Published var silenceThresholdDB: Float = -45
    @Published var availableSources: [AudioSourceUI] = [.all]
    @Published var selectedSourceID: String = AudioSourceUI.all.id
    @Published var identifyingFiles: Set<URL> = []
    @Published var identifyErrors: [URL: String] = [:]
    @Published var auddAPIKey: String = UserDefaults.standard.string(forKey: "auddAPIKey") ?? ""

    private var recorder: Recorder?
    private var nowPlaying: NowPlayingWatcher?
    private var timer: Timer?
    private var trackStart: Date?
    private var isStopping: Bool = false
    @Published var autoIdentifyEnabled: Bool = true

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let defaultDir = downloads.appendingPathComponent("MP3Download")
        let saved = UserDefaults.standard.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0) }
        self.outputDirectory = saved ?? defaultDir
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        refreshSources()
        loadExistingRecordings()
    }

    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
        UserDefaults.standard.set(url.path, forKey: "outputDirectory")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        loadExistingRecordings()
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where MP3Download saves and reads MP3 files"
        panel.prompt = "Select"
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            setOutputDirectory(url)
        }
    }

    func loadExistingRecordings() {
        identifyingFiles = []
        identifyErrors = [:]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            completedFiles = []
            return
        }
        completedFiles = urls
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
    }

    func refreshSources() {
        var list: [AudioSourceUI] = [.all]
        list.append(contentsOf: AudioProcessLister.list().map {
            AudioSourceUI(id: "pid-\($0.pid)", displayName: $0.displayName, pid: $0.pid)
        })
        availableSources = list
        if !list.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = AudioSourceUI.all.id
        }
    }

    func start() {
        guard recorder == nil else { return }
        isStopping = false
        status = .waitingForAudio
        let tapSource: TapSource
        if let selected = availableSources.first(where: { $0.id == selectedSourceID }), let pid = selected.pid {
            tapSource = .pid(pid)
        } else {
            tapSource = .all
        }
        let r = Recorder(
            outputDirectory: outputDirectory,
            source: tapSource,
            silenceSplitSeconds: silenceSplitSeconds,
            streamEndSeconds: streamEndSeconds,
            silenceThresholdDB: silenceThresholdDB
        )
        r.delegate = self
        recorder = r
        Task {
            do {
                try await r.start()
                await MainActor.run {
                    self.status = .waitingForAudio
                    self.nowPlaying = NowPlayingWatcher { [weak self] title in
                        self?.recorder?.updateCurrentTitle(title)
                        Task { @MainActor in self?.currentTrackTitle = title }
                    }
                    self.nowPlaying?.start()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.tick() }
                    }
                }
            } catch {
                await MainActor.run {
                    self.status = .error(error.localizedDescription)
                    self.recorder = nil
                }
            }
        }
    }

    func stop() {
        isStopping = true
        // recorder.stop() synchronously finalizes the current track and kicks off
        // its MP3 encode; the encoder holds a strong ref to Recorder so the
        // recorderDidFinishTrack callback still fires after we drop our ref here.
        recorder?.stop()
        recorder = nil
        nowPlaying?.stop()
        nowPlaying = nil
        timer?.invalidate()
        timer = nil
        status = .idle
        trackStart = nil
        elapsedSeconds = 0
        currentTrackTitle = ""
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func saveAPIKey() {
        UserDefaults.standard.set(auddAPIKey, forKey: "auddAPIKey")
    }

    func identify(_ url: URL) {
        guard !identifyingFiles.contains(url) else { return }
        identifyingFiles.insert(url)
        identifyErrors[url] = nil
        let key = auddAPIKey.isEmpty ? nil : auddAPIKey
        Task {
            do {
                let match = try await SongIdentifier.identify(audioURL: url, apiKey: key)
                await MainActor.run { self.applyIdentifyResult(url: url, match: match, error: nil) }
            } catch {
                await MainActor.run { self.applyIdentifyResult(url: url, match: nil, error: error.localizedDescription) }
            }
        }
    }

    func identifyAll() {
        for url in completedFiles where !identifyingFiles.contains(url) {
            identify(url)
        }
    }

    private func applyIdentifyResult(url: URL, match: SongIdentifier.Match?, error: String?) {
        identifyingFiles.remove(url)
        guard let match else {
            if let error { identifyErrors[url] = error }
            else        { identifyErrors[url] = "Not recognised" }
            return
        }
        do {
            let newURL = try SongIdentifier.rename(url, toBaseName: match.filename)
            if let idx = completedFiles.firstIndex(of: url) {
                completedFiles[idx] = newURL
            }
            identifyErrors[newURL] = nil
        } catch {
            identifyErrors[url] = "Rename failed: \(error.localizedDescription)"
        }
    }

    func openOutputDir() {
        NSWorkspace.shared.open(outputDirectory)
    }

    private func tick() {
        if let s = trackStart {
            elapsedSeconds = Date().timeIntervalSince(s)
        }
    }
}

extension AppState: RecorderDelegate {
    nonisolated func recorder(didUpdateLevelDB db: Float) {
        Task { @MainActor in self.currentLevelDB = db }
    }

    nonisolated func recorderDidStartTrack() {
        Task { @MainActor in
            guard !self.isStopping else { return }
            self.status = .recording
            self.trackStart = Date()
            self.elapsedSeconds = 0
        }
    }

    nonisolated func recorderDidFinishTrack(url: URL) {
        Task { @MainActor in
            // Avoid duplicates if a rescan happened to include this file already.
            if !self.completedFiles.contains(url) {
                self.completedFiles.append(url)
            }
            // Only return to waitingForAudio if we're still recording; if the
            // user pressed Stop, the encode that finishes after stop() must not
            // resurrect the recording UI.
            if !self.isStopping {
                self.status = .waitingForAudio
                self.trackStart = nil
                self.currentTrackTitle = ""
                self.recorder?.updateCurrentTitle(nil)
            }
            if self.autoIdentifyEnabled {
                self.identify(url)
            }
        }
    }

    nonisolated func recorderDidDetectStreamEnd() {
        Task { @MainActor in self.stop() }
    }

    nonisolated func recorderDidFail(_ message: String) {
        Task { @MainActor in
            self.status = .error(message)
            self.stop()
        }
    }

}

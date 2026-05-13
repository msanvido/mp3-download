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
    @Published var silenceSplitSeconds: Double = 1.0
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

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        self.outputDirectory = downloads.appendingPathComponent("MP3Download")
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        refreshSources()
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
        recorder?.stop()
        recorder = nil
        nowPlaying?.stop()
        nowPlaying = nil
        timer?.invalidate()
        timer = nil
        status = .idle
        trackStart = nil
        elapsedSeconds = 0
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
            self.status = .recording
            self.trackStart = Date()
            self.elapsedSeconds = 0
        }
    }

    nonisolated func recorderDidFinishTrack(url: URL) {
        Task { @MainActor in
            self.completedFiles.append(url)
            self.status = .waitingForAudio
            self.trackStart = nil
            // Clear the title so the next track starts blank until detected.
            self.currentTrackTitle = ""
            self.recorder?.updateCurrentTitle(nil)
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

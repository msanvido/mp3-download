import Foundation
import AVFoundation

protocol RecorderDelegate: AnyObject {
    func recorder(didUpdateLevelDB db: Float)
    func recorderDidStartTrack()
    func recorderDidFinishTrack(url: URL)
    func recorderDidDetectStreamEnd()
    func recorderDidFail(_ message: String)
    func recorderCurrentMetadataTitle() -> String?
}

extension RecorderDelegate {
    func recorderCurrentMetadataTitle() -> String? { nil }
}

/// Drives capture: pulls Float32 frames from AudioTap, runs silence detection,
/// writes a WAV per track, and shells out to `lame` to produce MP3.
final class Recorder {
    weak var delegate: RecorderDelegate?

    private let outputDirectory: URL
    private let silenceSplitSeconds: Double
    private let streamEndSeconds: Double
    private let silenceThresholdDB: Float

    private let tap: AudioTap
    private let workQueue = DispatchQueue(label: "MP3Download.Recorder.work", qos: .userInitiated)

    private var sampleRate: Double = 48000
    private var channelCount: Int = 2

    private var currentWavURL: URL?
    private var currentFile: AVAudioFile?
    private var hasSeenAudioInTrack = false
    private var lastAudioFrameTime: Double = 0   // seconds since recording started
    private var silenceRunFrames: Int = 0
    private var streamSilenceFrames: Int = 0
    private var totalFramesProcessed: Int = 0
    private var trackIndex: Int = 0
    private var ioProcCallbackCount: Int = 0
    private var watchdogTimer: DispatchSourceTimer?
    private var streamEndFired = false
    private var stopped = false

    private let lameURL: URL?
    private let titleLock = NSLock()
    private var currentTitle: String?

    func updateCurrentTitle(_ title: String?) {
        titleLock.lock(); defer { titleLock.unlock() }
        currentTitle = title
    }

    private func snapshotTitle() -> String? {
        titleLock.lock(); defer { titleLock.unlock() }
        return currentTitle
    }

    init(outputDirectory: URL, source: TapSource, silenceSplitSeconds: Double, streamEndSeconds: Double, silenceThresholdDB: Float) {
        self.outputDirectory = outputDirectory
        self.silenceSplitSeconds = silenceSplitSeconds
        self.streamEndSeconds = streamEndSeconds
        self.silenceThresholdDB = silenceThresholdDB
        self.lameURL = Self.locateLame()
        self.tap = AudioTap(source: source)
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        guard lameURL != nil else {
            throw NSError(domain: "Recorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "`lame` not found on PATH. Install with `brew install lame` then relaunch."
            ])
        }
        tap.onFrames = { [weak self] left, right, sampleRate in
            self?.handleFrames(left: left, right: right, sampleRate: sampleRate)
        }
        try await tap.start()
        sampleRate = tap.sampleRate
        channelCount = tap.channelCount
        startWatchdog()
    }

    /// Test-only: skip the audio tap, prep state so injected frames can drive the pipeline.
    func startForTesting(sampleRate: Double, channelCount: Int) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        guard lameURL != nil else {
            throw NSError(domain: "Recorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "`lame` not found on PATH."
            ])
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Test-only: feed a buffer of frames as if it had arrived from the tap.
    func injectFramesForTesting(left: [Float], right: [Float]?, sampleRate: Double) {
        handleFrames(left: left, right: right, sampleRate: sampleRate)
    }

    /// Test-only: block until any in-flight encode completion has drained.
    func waitForEncodingToFinish(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var idle = false
            workQueue.sync { idle = (self.currentFile == nil) }
            if idle { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.ioProcCallbackCount == 0 {
                self.delegate?.recorderDidFail(
                    "No audio data is reaching the tap.\n\n" +
                    "Most likely the app needs Audio Capture permission. Open " +
                    "System Settings → Privacy & Security → Audio Capture (or 'System Audio Recording Only') " +
                    "and enable MP3Download, then relaunch.\n\n" +
                    "If permission is already granted, try toggling it off and on, " +
                    "or run: tccutil reset SystemAudioCapture"
                )
            }
            self.watchdogTimer = nil
        }
        timer.resume()
        watchdogTimer = timer
    }

    func stop() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        tap.onFrames = nil
        tap.stop()
        workQueue.sync {
            self.stopped = true
            self.finalizeCurrentTrack(reason: .userStop)
        }
    }

    // MARK: - Frame handling (called on tap's IO queue)

    private func handleFrames(left: [Float], right: [Float]?, sampleRate: Double) {
        ioProcCallbackCount += 1
        let frameCount = left.count
        var sum: Float = 0
        for i in 0..<frameCount {
            let l = left[i]
            sum += l * l
            if let r = right { let rv = r[i]; sum += rv * rv }
        }
        let denom = Float(frameCount * (right != nil ? 2 : 1))
        let rms = sqrt(sum / max(1, denom))
        let db = 20 * log10(max(rms, 1e-7))
        delegate?.recorder(didUpdateLevelDB: db)

        workQueue.async { [weak self] in
            self?.processFrames(left: left, right: right, db: db, sampleRate: sampleRate)
        }
    }

    private enum FinalizeReason { case silenceSplit, streamEnd, userStop }

    private func processFrames(left: [Float], right: [Float]?, db: Float, sampleRate: Double) {
        if stopped { return }
        let frameCount = left.count
        totalFramesProcessed += frameCount
        let isSilent = db < silenceThresholdDB

        if isSilent {
            silenceRunFrames += frameCount
            streamSilenceFrames += frameCount
        } else {
            silenceRunFrames = 0
            streamSilenceFrames = 0
        }

        if !isSilent {
            // Start a new track on the first audio after silence.
            if currentFile == nil {
                do { try startNewTrack(sampleRate: sampleRate, channelCount: right == nil ? 1 : 2) }
                catch {
                    delegate?.recorderDidFail("Could not start WAV file: \(error.localizedDescription)")
                    return
                }
                hasSeenAudioInTrack = true
                streamEndFired = false
                delegate?.recorderDidStartTrack()
            }
            writeBuffer(left: left, right: right)
        } else if currentFile != nil, hasSeenAudioInTrack {
            // Still write some of the silence so cuts don't sound abrupt — up to split threshold.
            writeBuffer(left: left, right: right)
            let silenceSecs = Double(silenceRunFrames) / sampleRate
            if silenceSecs >= silenceSplitSeconds {
                finalizeCurrentTrack(reason: .silenceSplit)
                silenceRunFrames = 0   // don't re-finalize on the next silent frame
            }
        }

        // Long total silence with no recording in progress → stream is over.
        if currentFile == nil
            && !streamEndFired
            && Double(streamSilenceFrames) / sampleRate >= streamEndSeconds
            && totalFramesProcessed > Int(sampleRate * 2) {
            streamEndFired = true
            delegate?.recorderDidDetectStreamEnd()
        }
    }

    private func writeBuffer(left: [Float], right: [Float]?) {
        guard let file = currentFile else { return }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(left.count)
        if let ch = buffer.floatChannelData {
            left.withUnsafeBufferPointer { src in
                ch[0].update(from: src.baseAddress!, count: left.count)
            }
            if format.channelCount > 1 {
                if let right = right {
                    right.withUnsafeBufferPointer { src in
                        ch[1].update(from: src.baseAddress!, count: right.count)
                    }
                } else {
                    ch[1].update(from: left, count: left.count)
                }
            }
        }
        do { try file.write(from: buffer) }
        catch { delegate?.recorderDidFail("WAV write failed: \(error.localizedDescription)") }
    }

    private func startNewTrack(sampleRate: Double, channelCount: Int) throws {
        trackIndex += 1
        let ts = Self.timestampString()
        let baseName = "track-\(String(format: "%03d", trackIndex))-\(ts)"
        let wavURL = outputDirectory.appendingPathComponent("\(baseName).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: wavURL, settings: settings,
                                   commonFormat: processingFormat.commonFormat,
                                   interleaved: processingFormat.isInterleaved)
        currentFile = file
        currentWavURL = wavURL
        hasSeenAudioInTrack = false
        silenceRunFrames = 0
    }

    private func finalizeCurrentTrack(reason: FinalizeReason) {
        guard let wavURL = currentWavURL else { return }
        currentFile = nil   // closes the WAV file
        currentWavURL = nil
        hasSeenAudioInTrack = false

        let title = snapshotTitle()
        // Strong self: the Recorder must outlive its encoder so the delegate
        // fires even if the caller (e.g. AppState) released its reference on stop.
        encodeToMP3(wavURL: wavURL, title: title) { result in
            switch result {
            case .success(let mp3URL):
                self.delegate?.recorderDidFinishTrack(url: mp3URL)
            case .failure(let err):
                self.delegate?.recorderDidFail("Encoding failed: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - MP3 encoding (lame)

    private func encodeToMP3(wavURL: URL, title: String?, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let lameURL = lameURL else {
            completion(.failure(NSError(domain: "Recorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "lame binary not located."
            ])))
            return
        }
        // If we got a title, name the MP3 after it (sanitized); otherwise keep the wav's stem.
        let mp3URL: URL = {
            guard let raw = title, !raw.isEmpty else {
                return wavURL.deletingPathExtension().appendingPathExtension("mp3")
            }
            let safe = raw.replacingOccurrences(of: "/", with: "-")
                          .replacingOccurrences(of: ":", with: "-")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = wavURL.deletingPathExtension().lastPathComponent
            let prefix = String(stem.prefix(20))  // keep the track-NNN-timestamp prefix for uniqueness
            return wavURL.deletingLastPathComponent()
                         .appendingPathComponent("\(prefix) \(safe).mp3")
        }()

        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = lameURL
            var args = ["--quiet", "-V", "2"]
            if let title = title, !title.isEmpty {
                args.append(contentsOf: ["--tt", title])
            }
            args.append(wavURL.path)
            args.append(mp3URL.path)
            p.arguments = args
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: wavURL)
                    completion(.success(mp3URL))
                } else {
                    completion(.failure(NSError(domain: "Recorder", code: Int(p.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: "lame exited with code \(p.terminationStatus)"
                    ])))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Utilities

    private static func timestampString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }

    private static func locateLame() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/lame",
            "/usr/local/bin/lame",
            "/usr/bin/lame"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to `which lame` via /bin/sh
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "command -v lame"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch { /* ignore */ }
        return nil
    }
}

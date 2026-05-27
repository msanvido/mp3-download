import Foundation
import AppKit

/// Headless end-to-end test: capture system audio for N seconds and produce MP3 file(s).
/// Useful for verifying the full pipeline (capture → silence detect → WAV → lame → MP3).
enum AutoRecord {
    static func run(durationSeconds: Double) {
        let logURL = URL(fileURLWithPath: "/tmp/mp3download-autorecord.log")
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: logURL) else { exit(1) }
        func log(_ s: String) {
            let line = "\(s)\n"
            handle.write(line.data(using: .utf8)!)
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }

        let outputDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MP3Download-Test-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        log("=== AutoRecord (duration=\(durationSeconds)s) ===")
        log("Output dir: \(outputDir.path)")

        let recorder = Recorder(
            outputDirectory: outputDir,
            source: .all,
            silenceSplitSeconds: 0.5,
            streamEndSeconds: 600,        // disable stream-end auto-stop
            silenceThresholdDB: -45
        )
        let delegate = AutoDelegate(log: log)
        recorder.delegate = delegate

        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                try await recorder.start()
                log("recorder.start() OK")
                try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
                recorder.stop()
                log("recorder.stop() called")
                // wait a couple seconds for lame to finish
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                done.signal()
            } catch {
                log("recorder.start() FAILED: \(error.localizedDescription)")
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + durationSeconds + 15)

        let files = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.fileSizeKey]))?.sorted(by: { $0.path < $1.path }) ?? []
        log("\nFiles in output dir (\(files.count)):")
        for f in files {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            log("  \(f.lastPathComponent)  (\(size) bytes)")
        }
        log("=== DONE ===")
        handle.closeFile()
    }
}

final class AutoDelegate: RecorderDelegate {
    let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }
    func recorder(didUpdateLevelDB db: Float) { /* spammy */ }
    func recorderDidStartTrack() { log("[recorder] track started") }
    func recorderDidFinishTrack(url: URL) { log("[recorder] track finished: \(url.lastPathComponent)") }
    func recorderDidDetectStreamEnd() { log("[recorder] stream end detected") }
    func recorderDidFail(_ message: String) { log("[recorder] FAIL: \(message)") }
}

import Foundation

/// Headless synthetic-audio test that drives the Recorder pipeline without a real audio tap.
/// Verifies: silence-based splitting, that stop() finalizes the in-progress track, and that
/// the delegate fires recorderDidFinishTrack for every track — including after the caller
/// releases its strong reference to the Recorder (regression test for the "stop erases the
/// current track" bug, where the encode completion's [weak self] resolved to nil).
enum RecorderTest {
    final class Counters: RecorderDelegate {
        let lock = NSLock()
        var starts = 0
        var finished: [URL] = []
        var failures: [String] = []
        var streamEnds = 0
        func recorder(didUpdateLevelDB db: Float) {}
        func recorderDidStartTrack() {
            lock.lock(); starts += 1; lock.unlock()
        }
        func recorderDidFinishTrack(url: URL) {
            lock.lock(); finished.append(url); lock.unlock()
        }
        func recorderDidDetectStreamEnd() {
            lock.lock(); streamEnds += 1; lock.unlock()
        }
        func recorderDidFail(_ message: String) {
            lock.lock(); failures.append(message); lock.unlock()
        }
        func snapshot() -> (Int, [URL], [String], Int) {
            lock.lock(); defer { lock.unlock() }
            return (starts, finished, failures, streamEnds)
        }
    }

    static func run() -> Int32 {
        let logURL = URL(fileURLWithPath: "/tmp/mp3download-recordertest.log")
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        func log(_ s: String) {
            let line = s + "\n"
            handle?.write(line.data(using: .utf8)!)
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        let splitCaseOK = runSplitAndStop(log: log)
        let streamEndCaseOK = runStreamEndOnce(log: log)
        let pass = splitCaseOK && streamEndCaseOK
        log(pass ? "=== ALL TESTS PASSED ===" : "=== SOME TESTS FAILED ===")
        handle?.closeFile()
        return pass ? 0 : 1
    }

    private static func runSplitAndStop(log: (String) -> Void) -> Bool {

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MP3DownloadTest-\(UUID().uuidString)")
        log("=== RecorderTest: split + stop ===")
        log("output dir: \(outputDir.path)")

        let sr: Double = 48000
        let chunkSize = 1024
        let silenceSplit: Double = 0.5
        let threshold: Float = -45

        let counters = Counters()
        var recorder: Recorder? = Recorder(
            outputDirectory: outputDir,
            source: .all,
            silenceSplitSeconds: silenceSplit,
            streamEndSeconds: 60,           // disable auto stream-end in this test
            silenceThresholdDB: threshold
        )
        recorder!.delegate = counters
        do {
            try recorder!.startForTesting(sampleRate: sr, channelCount: 2)
        } catch {
            log("startForTesting failed: \(error.localizedDescription)")
            return false
        }

        // Helpers to push audio in realistic chunk sizes.
        func sineChunk(count: Int, phase: inout Double) -> ([Float], [Float]) {
            var l = [Float](repeating: 0, count: count)
            var r = [Float](repeating: 0, count: count)
            let freq = 440.0
            let twoPi = 2 * Double.pi
            for i in 0..<count {
                let v = Float(0.25 * sin(phase))
                l[i] = v; r[i] = v
                phase += twoPi * freq / sr
            }
            return (l, r)
        }
        var phase: Double = 0
        func pushSine(durationSec: Double) {
            var remaining = Int(durationSec * sr)
            while remaining > 0 {
                let n = min(chunkSize, remaining)
                let (l, r) = sineChunk(count: n, phase: &phase)
                recorder?.injectFramesForTesting(left: l, right: r, sampleRate: sr)
                remaining -= n
            }
        }
        func pushSilence(durationSec: Double) {
            var remaining = Int(durationSec * sr)
            while remaining > 0 {
                let n = min(chunkSize, remaining)
                let l = [Float](repeating: 0, count: n)
                let r = [Float](repeating: 0, count: n)
                recorder?.injectFramesForTesting(left: l, right: r, sampleRate: sr)
                remaining -= n
            }
        }

        // 3 sine bursts separated by silences longer than silenceSplit.
        // The last burst is followed by stop() with NO trailing silence — it should
        // still be finalized.
        pushSine(durationSec: 1.5)
        pushSilence(durationSec: 0.8)        // > 0.5 → split #1
        pushSine(durationSec: 1.5)
        pushSilence(durationSec: 0.8)        // > 0.5 → split #2
        pushSine(durationSec: 1.5)
        // Drop strong ref AFTER calling stop. If the encode completion only held
        // self weakly, the third track's encode would orphan and finalize wouldn't fire.
        recorder?.stop()
        let weakRecorder = recorder
        recorder = nil
        _ = weakRecorder   // silence unused warning; we don't call into it after stop
        log("issued stop(); waiting for encodes…")

        // Wait up to 20s for 3 finalized MP3s.
        let deadline = Date().addingTimeInterval(20)
        var snap = counters.snapshot()
        while Date() < deadline {
            snap = counters.snapshot()
            if snap.1.count >= 3 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let (starts, finished, failures, streamEnds) = snap
        log("starts=\(starts) finished=\(finished.count) failures=\(failures.count) streamEnds=\(streamEnds)")
        for u in finished { log("  finished: \(u.lastPathComponent)") }
        for f in failures { log("  FAIL: \(f)") }

        let files = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let mp3s = files.filter { $0.pathExtension.lowercased() == "mp3" }
        let wavs = files.filter { $0.pathExtension.lowercased() == "wav" }
        log("on disk: \(mp3s.count) mp3, \(wavs.count) wav")
        for u in mp3s {
            let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            log("  \(u.lastPathComponent) (\(sz) bytes)")
        }

        var failed = false
        func expect(_ cond: Bool, _ msg: String) {
            if cond { log("PASS \(msg)") }
            else    { log("FAIL \(msg)"); failed = true }
        }
        expect(starts == 3,            "3 tracks started (got \(starts))")
        expect(finished.count == 3,    "3 tracks finished (got \(finished.count))")
        expect(mp3s.count == 3,        "3 MP3 files on disk (got \(mp3s.count))")
        expect(wavs.isEmpty,           "no leftover WAV files (got \(wavs.count))")
        expect(failures.isEmpty,       "no recorder failures (got \(failures.count))")
        expect(streamEnds == 0,        "no spurious stream-end (got \(streamEnds))")
        expect(mp3s.allSatisfy { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 1000 },
               "all MP3s > 1KB")

        // Cleanup
        try? FileManager.default.removeItem(at: outputDir)
        log(failed ? "[split+stop] FAILED" : "[split+stop] PASSED")
        return !failed
    }

    /// Stream-end detection should fire exactly once when silence persists past
    /// streamEndSeconds with no current track, and not again on subsequent silent frames.
    private static func runStreamEndOnce(log: (String) -> Void) -> Bool {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MP3DownloadTest-\(UUID().uuidString)")
        log("=== RecorderTest: stream-end fires once ===")
        log("output dir: \(outputDir.path)")

        let sr: Double = 48000
        let chunkSize = 1024
        let counters = Counters()
        let recorder = Recorder(
            outputDirectory: outputDir,
            source: .all,
            silenceSplitSeconds: 0.5,
            streamEndSeconds: 1.0,          // short, for the test
            silenceThresholdDB: -45
        )
        recorder.delegate = counters
        do {
            try recorder.startForTesting(sampleRate: sr, channelCount: 2)
        } catch {
            log("startForTesting failed: \(error.localizedDescription)")
            return false
        }

        var phase: Double = 0
        func sineChunk(count: Int) -> ([Float], [Float]) {
            var l = [Float](repeating: 0, count: count)
            var r = [Float](repeating: 0, count: count)
            let twoPi = 2 * Double.pi
            for i in 0..<count {
                let v = Float(0.25 * sin(phase))
                l[i] = v; r[i] = v
                phase += twoPi * 440 / sr
            }
            return (l, r)
        }
        func pushSine(_ d: Double) {
            var remaining = Int(d * sr)
            while remaining > 0 {
                let n = min(chunkSize, remaining)
                let (l, r) = sineChunk(count: n)
                recorder.injectFramesForTesting(left: l, right: r, sampleRate: sr)
                remaining -= n
            }
        }
        func pushSilence(_ d: Double) {
            var remaining = Int(d * sr)
            while remaining > 0 {
                let n = min(chunkSize, remaining)
                let l = [Float](repeating: 0, count: n)
                let r = [Float](repeating: 0, count: n)
                recorder.injectFramesForTesting(left: l, right: r, sampleRate: sr)
                remaining -= n
            }
        }

        pushSine(1.0)             // one track
        pushSilence(3.0)          // > streamEndSeconds (1.0); should fire stream-end once
        pushSilence(2.0)          // additional silence; should NOT fire again
        recorder.stop()

        // Give the encoder time to finish the one finalized track.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if counters.snapshot().1.count >= 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let snap = counters.snapshot()
        log("starts=\(snap.0) finished=\(snap.1.count) failures=\(snap.2.count) streamEnds=\(snap.3)")

        var failed = false
        func expect(_ cond: Bool, _ msg: String) {
            if cond { log("PASS \(msg)") }
            else    { log("FAIL \(msg)"); failed = true }
        }
        expect(snap.0 == 1,           "exactly 1 track started (got \(snap.0))")
        expect(snap.1.count == 1,     "exactly 1 track finished (got \(snap.1.count))")
        expect(snap.3 == 1,           "stream-end fired exactly once (got \(snap.3))")
        expect(snap.2.isEmpty,        "no failures (got \(snap.2.count))")

        try? FileManager.default.removeItem(at: outputDir)
        log(failed ? "[stream-end] FAILED" : "[stream-end] PASSED")
        return !failed
    }
}

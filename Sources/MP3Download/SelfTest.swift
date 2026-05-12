import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Headless test that exercises the full permission + tap + capture pipeline.
/// Writes structured output to /tmp/mp3download-selftest.log AND stderr.
enum SelfTest {
    static func run() {
        let logURL = URL(fileURLWithPath: "/tmp/mp3download-selftest.log")
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            fputs("Couldn't open log\n", stderr); exit(1)
        }
        func log(_ s: String) {
            let line = s + "\n"
            handle.write(line.data(using: .utf8)!)
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }

        log("=== MP3Download self-test ===")
        log("Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")
        log("PID: \(getpid())")

        // 1. Microphone status + request
        log("\nMicrophone status: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) " +
            "(0=notDetermined,1=restricted,2=denied,3=authorized)")
        let sem = DispatchSemaphore(value: 0)
        var micGranted = false
        AVCaptureDevice.requestAccess(for: .audio) { g in micGranted = g; sem.signal() }
        log("Requested microphone access… (allow the prompt if it appears)")
        _ = sem.wait(timeout: .now() + 60)
        log("Microphone request returned: granted=\(micGranted)")
        log("Microphone status now: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")

        // 2. TCC preflight for SystemAudioCaptureOnly
        if let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY) {
            typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
            typealias RequestFn = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void
            if let psym = dlsym(h, "TCCAccessPreflight") {
                let pfn = unsafeBitCast(psym, to: PreflightFn.self)
                func name(_ v: Int32) -> String { v == 0 ? "GRANTED" : v == 1 ? "PROMPT" : v == 2 ? "DENIED" : "UNK(\(v))" }
                for svc in ["kTCCServiceMicrophone", "kTCCServiceAudioCapture",
                            "kTCCServiceSystemAudioCaptureOnly", "kTCCServiceScreenCapture"] {
                    log("  \(svc): \(name(pfn(svc as CFString, nil)))")
                }
                // Request SystemAudioCaptureOnly
                if let rsym = dlsym(h, "TCCAccessRequest") {
                    let rfn = unsafeBitCast(rsym, to: RequestFn.self)
                    let svc = "kTCCServiceSystemAudioCaptureOnly"
                    if pfn(svc as CFString, nil) != 0 {
                        log("\nRequesting \(svc)…")
                        let box = NSMutableArray()
                        let s2 = DispatchSemaphore(value: 0)
                        let cb: @convention(block) (Bool) -> Void = { g in box.add(g); s2.signal() }
                        rfn(svc as CFString, nil, cb)
                        _ = s2.wait(timeout: .now() + 60)
                        log("  result: granted=\((box.firstObject as? Bool) ?? false)")
                        log("  preflight after: \(name(pfn(svc as CFString, nil)))")
                    }
                }
            }
        }

        // 3. SCStream-based audio capture
        log("\n=== ScreenCaptureKit audio capture ===")
        let sckSem = DispatchSemaphore(value: 0)
        let counter = SCKCounter()
        var sckErr: String?
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                log("  SCShareableContent OK: \(content.displays.count) display(s), \(content.applications.count) app(s)")
                guard let display = content.displays.first else {
                    sckErr = "No displays"; sckSem.signal(); return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let stream = SCStream(filter: filter, configuration: config, delegate: counter)
                try stream.addStreamOutput(counter, type: .audio,
                                           sampleHandlerQueue: DispatchQueue(label: "selftest.audio"))
                try stream.addStreamOutput(counter, type: .screen,
                                           sampleHandlerQueue: DispatchQueue(label: "selftest.screen"))
                try await stream.startCapture()
                log("  SCStream startCapture OK")
                // Run 8 seconds
                for i in 1...8 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let cb = counter.audioCallbacks
                    let maxR = counter.maxRMS
                    let db = maxR > 0 ? 20 * log10(maxR) : -Float.infinity
                    log(String(format: "  t=%ds audioCallbacks=%d screenCallbacks=%d maxRMS=%.5f (%.1f dBFS)",
                               i, cb, counter.screenCallbacks, maxR, db))
                }
                try? await stream.stopCapture()
                log("  SCStream stopCapture done. final audioCallbacks=\(counter.audioCallbacks)")
                sckSem.signal()
            } catch {
                sckErr = error.localizedDescription
                log("  SCStream error: \(error)")
                sckSem.signal()
            }
        }
        _ = sckSem.wait(timeout: .now() + 30)
        if let sckErr = sckErr { log("  SCStream FAILED: \(sckErr)") }

        // 4. (legacy) keep the old Process Tap path running too for comparison
        log("\n=== Legacy Core Audio Process Tap (for comparison) ===")
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.isExclusive = false

        var tapID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        log("AudioHardwareCreateProcessTap: \(err) tapID=\(tapID)")
        guard err == noErr else { handle.closeFile(); exit(2) }

        // Get tap UID
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<CFString>.size)
        _ = withUnsafeMutablePointer(to: &cf) { p -> OSStatus in
            p.withMemoryRebound(to: UInt8.self, capacity: Int(sz)) { _ in
                AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &sz, p)
            }
        }
        guard let tapCF = cf?.takeRetainedValue() else { exit(3) }
        let tapUID = tapCF as String

        // default output
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var dsz = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil, &dsz, &dev)
        var outUIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ocf: Unmanaged<CFString>?
        var osz = UInt32(MemoryLayout<CFString>.size)
        _ = withUnsafeMutablePointer(to: &ocf) { p -> OSStatus in
            p.withMemoryRebound(to: UInt8.self, capacity: Int(osz)) { _ in
                AudioObjectGetPropertyData(dev, &outUIDAddr, 0, nil, &osz, p)
            }
        }
        let outUID = (ocf?.takeRetainedValue() as String?) ?? ""
        log("Default output device: id=\(dev) uid=\(outUID)")

        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MP3Download SelfTest",
            kAudioAggregateDeviceUIDKey: "MP3Download.SelfTest.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: 1
            ]]
        ]
        var aggID: AudioDeviceID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
        log("AudioHardwareCreateAggregateDevice: \(err) aggID=\(aggID)")

        final class Counters { var cb: Int64 = 0; var maxRMS: Float = 0; let lock = NSLock() }
        let c = Counters()
        var pid: AudioDeviceIOProcID?
        let q = DispatchQueue(label: "selftest.ioproc", qos: .userInteractive)
        let installErr = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, q) { _, inData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            c.lock.lock(); c.cb += 1; c.lock.unlock()
            guard abl.count > 0 else { return }
            let first = abl[0]
            let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard total > 0, let m = first.mData else { return }
            let fp = m.assumingMemoryBound(to: Float.self)
            var s: Float = 0
            for i in 0..<total { s += fp[i] * fp[i] }
            let rms = sqrt(s / Float(total))
            c.lock.lock(); if rms > c.maxRMS { c.maxRMS = rms }; c.lock.unlock()
        }
        log("IOProc install: \(installErr)")
        let startErr = AudioDeviceStart(aggID, pid)
        log("AudioDeviceStart: \(startErr)")

        log("\nCapturing for 10 seconds. Audio should be playing now.")
        for i in 1...10 {
            Thread.sleep(forTimeInterval: 1)
            c.lock.lock(); let cb = c.cb; let max = c.maxRMS; c.lock.unlock()
            let db = max > 0 ? 20 * log10(max) : -Float.infinity
            log(String(format: "  t=%2ds callbacks=%lld maxRMS=%.5f (%.1f dBFS)", i, cb, max, db))
        }

        AudioDeviceStop(aggID, pid)
        if let p = pid { AudioDeviceDestroyIOProcID(aggID, p) }
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
        log("\n=== DONE ===")
        handle.closeFile()
    }
}

final class SCKCounter: NSObject, SCStreamOutput, SCStreamDelegate {
    var audioCallbacks = 0
    var screenCallbacks = 0
    var maxRMS: Float = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { screenCallbacks += 1; return }
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        audioCallbacks += 1
        guard let fdesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(fdesc) else { return }
        let asbd = asbdP.pointee
        let chans = max(1, Int(asbd.mChannelsPerFrame))
        var blockBuffer: CMBlockBuffer?
        let abl = AudioBufferList.allocate(maximumBuffers: chans)
        defer { free(abl.unsafeMutablePointer) }
        let err = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: chans),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard err == noErr, abl.count > 0, let m = abl[0].mData else { return }
        let total = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
        let fp = m.assumingMemoryBound(to: Float.self)
        var s: Float = 0
        for i in 0..<total { s += fp[i] * fp[i] }
        let rms = sqrt(s / Float(total))
        if rms > maxRMS { maxRMS = rms }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}

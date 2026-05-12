import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AppKit

/// System audio capture via ScreenCaptureKit (macOS 13+).
/// Uses the Screen Recording / Screen & System Audio Recording TCC category, which is
/// a public, supported permission UX. Replaces our earlier Core Audio Process Tap.
final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias FrameHandler = (_ left: [Float], _ right: [Float]?, _ sampleRate: Double) -> Void

    private(set) var sampleRate: Double = 48000
    private(set) var channelCount: Int = 2

    private let source: TapSource
    private var stream: SCStream?
    private var lastError: Error?

    var onFrames: FrameHandler?

    init(source: TapSource) {
        self.source = source
    }

    func start() async throws {
        // SCShareableContent.current triggers the Screen Recording prompt if needed,
        // and throws if denied — so this also gates our permission flow.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw NSError(domain: "AudioTap", code: -10, userInfo: [
                NSLocalizedDescriptionKey:
                    "Screen Recording permission is required to capture system audio.\n\n" +
                    "Open System Settings → Privacy & Security → Screen & System Audio Recording " +
                    "(or 'Screen Recording'), enable MP3 Download, then relaunch the app.\n\n" +
                    "Underlying error: \(error.localizedDescription)"
            ])
        }

        guard let display = content.displays.first else {
            throw NSError(domain: "AudioTap", code: -11, userInfo: [
                NSLocalizedDescriptionKey: "No display available for capture."
            ])
        }

        let filter: SCContentFilter
        switch source {
        case .all:
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .pid(let pid):
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw NSError(domain: "AudioTap", code: -12, userInfo: [
                    NSLocalizedDescriptionKey: "Selected app (pid \(pid)) is not currently visible to the capture system. Make sure it has a visible window."
                ])
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Audio-only setup: keep the video stream tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        sampleRate = Double(config.sampleRate)
        channelCount = config.channelCount

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "MP3Download.AudioSCK", qos: .userInteractive))
        // We must add a screen output too (even if we don't read frames), otherwise SCStream
        // refuses to start on some macOS versions.
        try stream.addStreamOutput(NullScreenOutput.shared, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "MP3Download.SCKScreenSink"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task.detached {
            try? await stream.stopCapture()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let (left, right, sr) = Self.extractFloat32(sampleBuffer) else { return }
        onFrames?(left, right, sr)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = error
    }

    // MARK: - Sample buffer extraction

    private static func extractFloat32(_ sampleBuffer: CMSampleBuffer) -> ([Float], [Float]?, Double)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000

        var blockBuffer: CMBlockBuffer?
        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(abl.unsafeMutablePointer) }

        let err = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard err == noErr, abl.count >= 1 else { return nil }

        let buf0 = abl[0]
        let chansInBuf = max(1, Int(buf0.mNumberChannels))
        let totalSamples = Int(buf0.mDataByteSize) / MemoryLayout<Float>.size
        guard totalSamples > 0, let mData = buf0.mData else { return nil }
        let basePtr = mData.assumingMemoryBound(to: Float.self)

        if chansInBuf >= 2 {
            // Interleaved stereo
            let frameCount = totalSamples / chansInBuf
            var left = [Float](repeating: 0, count: frameCount)
            var right = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                left[i]  = basePtr[i * chansInBuf]
                right[i] = basePtr[i * chansInBuf + 1]
            }
            return (left, right, sampleRate)
        } else {
            // Non-interleaved: one buffer per channel
            let frameCount = totalSamples
            let left = Array(UnsafeBufferPointer(start: basePtr, count: frameCount))
            var right: [Float]?
            if abl.count >= 2, let rData = abl[1].mData {
                let rCount = Int(abl[1].mDataByteSize) / MemoryLayout<Float>.size
                let rp = rData.assumingMemoryBound(to: Float.self)
                right = Array(UnsafeBufferPointer(start: rp, count: rCount))
            }
            return (left, right, sampleRate)
        }
    }
}

/// SCStream requires at least one screen output to be attached. We add a no-op sink.
final class NullScreenOutput: NSObject, SCStreamOutput {
    static let shared = NullScreenOutput()
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Intentionally empty.
    }
}

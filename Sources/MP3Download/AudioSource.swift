import Foundation
import CoreAudio
import AppKit

/// What audio to capture.
enum TapSource: Equatable {
    case all
    case pid(pid_t)
}

/// Identifies a selectable source for the UI. Stable across app restarts via pid.
struct AudioSourceUI: Identifiable, Hashable {
    let id: String
    let displayName: String
    let pid: pid_t?   // nil for "all"

    static let all = AudioSourceUI(id: "all", displayName: "All system audio", pid: nil)
}

enum AudioProcessLister {
    struct Info {
        let pid: pid_t
        let audioObjectID: AudioObjectID
        let displayName: String
        let bundleID: String?
    }

    /// Audio-capable processes the system knows about (the system maintains this list).
    static func list() -> [Info] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let err = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, buf.baseAddress!)
        }
        guard err == noErr else { return [] }

        var seen = Set<pid_t>()
        var out: [Info] = []
        for objID in ids {
            guard let pid = pid(for: objID), !seen.contains(pid) else { continue }
            seen.insert(pid)
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            // Skip background helpers / our own process.
            if pid == getpid() { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
            // Skip system processes like coreaudiod, WindowServer, etc.
            if let bundle = app.bundleIdentifier,
               bundle.hasPrefix("com.apple.coreaudio") || bundle.hasPrefix("com.apple.audio.") {
                continue
            }
            out.append(Info(pid: pid, audioObjectID: objID, displayName: name, bundleID: app.bundleIdentifier))
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Re-resolve a pid to a current AudioObjectID at recording start.
    static func audioObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inPID = pid
        var outID: AudioObjectID = 0
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout.size(ofValue: inPID)),
            &inPID,
            &outSize,
            &outID
        )
        guard err == noErr, outID != 0 else { return nil }
        return outID
    }

    private static func pid(for processObject: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &pid)
        return err == noErr && pid > 0 ? pid : nil
    }
}

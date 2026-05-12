import Foundation
import AVFoundation
import Darwin

/// Permission gating for Core Audio Process Taps.
///
/// On macOS 14.4+, system audio capture via Process Taps is gated by two TCC categories:
///  - `kTCCServiceMicrophone`        — requested via `AVCaptureDevice.requestAccess(for: .audio)`
///  - `kTCCServiceSystemAudioCaptureOnly` — only reachable via the private `TCCAccessRequest`
///
/// We request both. The microphone permission is what most actually-working open-source
/// projects (AudioCap etc.) rely on; the second is for completeness in case Apple shifts
/// the gating mechanism on a given macOS version.
enum AudioCapturePermissions {

    static func currentStatus() -> Status {
        let mic = micStatus()
        let sysCap = preflight("kTCCServiceSystemAudioCaptureOnly")
        if mic == .authorized && sysCap == 0 { return .granted }
        if mic == .denied || sysCap == 2 { return .denied }
        return .promptRequired
    }

    enum Status { case granted, denied, promptRequired }

    /// Request both permissions in sequence, calling `completion` on the main queue.
    static func request(completion: @escaping (Bool, String?) -> Void) {
        let micResult = micStatus()
        let micDone: (Bool) -> Void = { micGranted in
            // Then request SystemAudioCaptureOnly via private API.
            requestSystemAudioCaptureOnly { sysGranted, sysMessage in
                DispatchQueue.main.async {
                    if !micGranted {
                        completion(false, "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone, then relaunch.")
                    } else if !sysGranted {
                        completion(false, sysMessage ?? "System Audio Recording permission denied. Open System Settings → Privacy & Security → Microphone (and any 'Audio Recording' or 'System Audio Recording' panel) and enable MP3 Download.")
                    } else {
                        completion(true, nil)
                    }
                }
            }
        }
        switch micResult {
        case .authorized: micDone(true)
        case .denied:     micDone(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in micDone(granted) }
        @unknown default: micDone(false)
        }
    }

    private static func micStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Private TCC bridges

    private typealias TCCAccessPreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias TCCAccessRequestFunc = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private static let tccHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY
    )

    /// Returns 0=granted, 1=prompt, 2=denied, -1=unknown.
    private static func preflight(_ service: String) -> Int32 {
        guard let sym = tccHandle.flatMap({ dlsym($0, "TCCAccessPreflight") }) else { return -1 }
        let fn = unsafeBitCast(sym, to: TCCAccessPreflightFunc.self)
        return fn(service as CFString, nil)
    }

    private static func requestSystemAudioCaptureOnly(_ completion: @escaping (Bool, String?) -> Void) {
        let service = "kTCCServiceSystemAudioCaptureOnly"
        let pre = preflight(service)
        if pre == 0 {
            completion(true, nil); return
        }
        guard let sym = tccHandle.flatMap({ dlsym($0, "TCCAccessRequest") }) else {
            // Can't request via private API; fall back to checking current state.
            completion(pre == 0, pre == 2 ? "System Audio Recording permission denied." : nil)
            return
        }
        let fn = unsafeBitCast(sym, to: TCCAccessRequestFunc.self)
        let box = NSMutableArray()
        let sem = DispatchSemaphore(value: 0)
        let callback: @convention(block) (Bool) -> Void = { granted in
            box.add(granted)
            sem.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            fn(service as CFString, nil, callback)
            _ = sem.wait(timeout: .now() + 60)
            let granted = (box.firstObject as? Bool) ?? false
            let after = preflight(service)
            completion(granted || after == 0, nil)
        }
    }

    static func openSystemSettingsPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

import AppKit

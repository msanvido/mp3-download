import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import Darwin

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func fourCC(_ v: OSStatus) -> String {
    let bytes: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    if bytes.allSatisfy({ (0x20...0x7e).contains($0) }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "' (\(v))"
    }
    return String(v)
}

// --- TCC preflight ---
typealias TCCAccessPreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32
typealias TCCAccessRequestFunc = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY)
let preflightSym = tccHandle.flatMap { dlsym($0, "TCCAccessPreflight") }
let preflight: TCCAccessPreflightFunc? = preflightSym.map { unsafeBitCast($0, to: TCCAccessPreflightFunc.self) }

func tccLabel(_ v: Int32) -> String {
    switch v {
    case 0: return "GRANTED"
    case 1: return "PROMPT"
    case 2: return "DENIED"
    default: return "UNKNOWN(\(v))"
    }
}

log("=== TCC Preflight ===")
let services = ["kTCCServiceAudioCapture", "kTCCServiceMicrophone", "kTCCServiceScreenCapture", "kTCCServiceSystemAudioCaptureOnly", "kTCCServiceSystemAudioRecordingOnly"]
if let preflight = preflight {
    for svc in services {
        let result = preflight(svc as CFString, nil)
        log("  \(svc): \(tccLabel(result))")
    }
} else {
    log("  (TCCAccessPreflight unavailable)")
}

// Explicitly request SystemAudioCaptureOnly. This should pop a permission prompt.
let requestSym = tccHandle.flatMap { dlsym($0, "TCCAccessRequest") }
if let requestSym = requestSym, let preflight = preflight {
    let request = unsafeBitCast(requestSym, to: TCCAccessRequestFunc.self)
    let svc = "kTCCServiceSystemAudioCaptureOnly"
    let before = preflight(svc as CFString, nil)
    if before != 0 {
        log("\n=== Requesting permission for \(svc) ===")
        log("If a system prompt appears, click Allow. Waiting up to 30s…")
        let sem = DispatchSemaphore(value: 0)
        let grantedBox = NSMutableArray()
        let callback: @convention(block) (Bool) -> Void = { g in
            grantedBox.add(g)
            sem.signal()
        }
        request(svc as CFString, nil, callback)
        let waitResult = sem.wait(timeout: .now() + 30)
        let granted = (grantedBox.firstObject as? Bool) ?? false
        log("  request callback: timeout=\(waitResult == .timedOut) granted=\(granted)")
        let after = preflight(svc as CFString, nil)
        log("  preflight after request: \(tccLabel(after))")
    } else {
        log("\n\(svc) already GRANTED — proceeding.")
    }
}

// --- pick mode from argv ---
let mode = CommandLine.arguments.dropFirst().first ?? "global"
log("\n=== Tap Mode: \(mode) ===")

let desc: CATapDescription
switch mode {
case "global":
    desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
case "process":
    // Find an audio process to target (skip ours).
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    _ = AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    _ = ids.withUnsafeMutableBufferPointer { buf in
        AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, buf.baseAddress!)
    }
    log("  Audio-capable processes (\(count)):")
    var chosen: AudioObjectID = 0
    var chosenName = ""
    for objID in ids {
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var sz = UInt32(MemoryLayout<pid_t>.size)
        if AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &sz, &pid) == noErr, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid) {
            let n = app.localizedName ?? "PID \(pid)"
            log("    objID=\(objID) pid=\(pid) name=\(n)")
            if chosen == 0 && pid != getpid() {
                chosen = objID
                chosenName = n
            }
        }
    }
    if chosen == 0 {
        log("  No suitable audio process found.")
        exit(1)
    }
    log("  Targeting: \(chosenName) (objID \(chosen))")
    desc = CATapDescription(stereoMixdownOfProcesses: [chosen])
default:
    log("Unknown mode: \(mode)")
    exit(99)
}
desc.uuid = UUID()
desc.muteBehavior = .unmuted
desc.isPrivate = true
desc.isExclusive = false

log("\n=== Creating tap ===")
var tapID: AudioObjectID = kAudioObjectUnknown
let err1 = AudioHardwareCreateProcessTap(desc, &tapID)
log("AudioHardwareCreateProcessTap → \(fourCC(err1)) tapID=\(tapID)")
guard err1 == noErr else { exit(2) }

var uidAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var cfString: Unmanaged<CFString>?
var uidSize = UInt32(MemoryLayout<CFString>.size)
let uidErr = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
    ptr.withMemoryRebound(to: UInt8.self, capacity: Int(uidSize)) { _ in
        AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, ptr)
    }
}
guard uidErr == noErr, let tapUIDCF = cfString?.takeRetainedValue() else {
    log("FAILED tap UID \(fourCC(uidErr))"); exit(3)
}
let tapUID = tapUIDCF as String
log("Tap UID = \(tapUID)")

// default output
var outAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var outDev: AudioDeviceID = 0
var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
_ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil, &outSize, &outDev)
var outUIDAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var outUIDCF: Unmanaged<CFString>?
var outUIDSize = UInt32(MemoryLayout<CFString>.size)
_ = withUnsafeMutablePointer(to: &outUIDCF) { ptr -> OSStatus in
    ptr.withMemoryRebound(to: UInt8.self, capacity: Int(outUIDSize)) { _ in
        AudioObjectGetPropertyData(outDev, &outUIDAddr, 0, nil, &outUIDSize, ptr)
    }
}
let outUID = (outUIDCF?.takeRetainedValue() as String?) ?? ""
log("default output device id=\(outDev) UID=\(outUID)")

let aggUID = "MP3Download.TapTest.\(UUID().uuidString)"
let dict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Tap Test",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceIsStackedKey: 0,
    kAudioAggregateDeviceTapAutoStartKey: 1,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outUID]
    ],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: tapUID,
        kAudioSubTapDriftCompensationKey: 1
    ]]
]
var aggID: AudioDeviceID = kAudioObjectUnknown
let aggErr = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
log("aggregate id=\(aggID) (\(fourCC(aggErr)))")
guard aggErr == noErr else { exit(5) }

final class Counters {
    var frames: Int64 = 0
    var callbacks: Int64 = 0
    var maxRMS: Float = 0
    let lock = NSLock()
}
let counters = Counters()

var procID: AudioDeviceIOProcID?
let queue = DispatchQueue(label: "tap.test.ioproc", qos: .userInteractive)
let installErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    counters.lock.lock(); counters.callbacks += 1; counters.lock.unlock()
    if abl.count == 0 { return }
    let first = abl[0]
    let totalSamples = Int(first.mDataByteSize) / MemoryLayout<Float>.size
    guard totalSamples > 0, let mData = first.mData else { return }
    let fp = mData.assumingMemoryBound(to: Float.self)
    var sum: Float = 0
    for i in 0..<totalSamples { sum += fp[i] * fp[i] }
    let rms = sqrt(sum / Float(totalSamples))
    counters.lock.lock()
    counters.frames += Int64(totalSamples / max(1, Int(first.mNumberChannels)))
    if rms > counters.maxRMS { counters.maxRMS = rms }
    counters.lock.unlock()
}
log("install: \(fourCC(installErr))")
guard installErr == noErr, procID != nil else { exit(6) }

let startErr = AudioDeviceStart(aggID, procID)
log("start: \(fourCC(startErr))")
guard startErr == noErr else { exit(7) }

log("\nCapturing for 6 seconds. Play audio now.")
for i in 1...6 {
    Thread.sleep(forTimeInterval: 1.0)
    counters.lock.lock()
    let cbs = counters.callbacks, frames = counters.frames, maxR = counters.maxRMS
    counters.lock.unlock()
    let db = maxR > 0 ? 20 * log10(maxR) : -Float.infinity
    log(String(format: "  t=%ds callbacks=%lld frames=%lld maxRMS=%.5f (%.1f dBFS)", i, cbs, frames, maxR, db))
}

AudioDeviceStop(aggID, procID)
if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
log("=== Done ===")

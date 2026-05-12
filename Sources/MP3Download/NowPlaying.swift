import Foundation
import AppKit

/// Best-effort "now playing" watcher.
/// Strategy: every 2 seconds, ask whichever streaming app is frontmost (or running) for current track.
/// - Apple Music ("Music"): AppleScript dictionary, reliable.
/// - Spotify: AppleScript dictionary, reliable.
/// - Amazon Music: no AppleScript dictionary. Falls back to reading the window title via Accessibility,
///   which requires the user to grant Accessibility permission. If not granted, we just skip it.
///
/// This is informational only — song splitting is driven by silence detection.
final class NowPlayingWatcher {
    private let onTitle: (String) -> Void
    private var timer: Timer?
    private var lastTitle: String = ""

    init(onTitle: @escaping (String) -> Void) {
        self.onTitle = onTitle
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let title = self.detect()
            if !title.isEmpty, title != self.lastTitle {
                self.lastTitle = title
                DispatchQueue.main.async { self.onTitle(title) }
            }
        }
    }

    private func detect() -> String {
        if isRunning(bundleID: "com.apple.Music"), let t = appleMusicTrack() { return t }
        if isRunning(bundleID: "com.spotify.client"), let t = spotifyTrack() { return t }
        if isRunning(bundleID: "com.amazon.music"), let t = amazonMusicTrack() { return t }
        return ""
    }

    private func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func appleMusicTrack() -> String? {
        runAppleScript("""
            if application "Music" is running then
                tell application "Music"
                    if player state is playing then
                        return (artist of current track as string) & " — " & (name of current track as string)
                    end if
                end tell
            end if
            return ""
        """)
    }

    private func spotifyTrack() -> String? {
        runAppleScript("""
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is playing then
                        return (artist of current track as string) & " — " & (name of current track as string)
                    end if
                end tell
            end if
            return ""
        """)
    }

    /// Amazon Music has no scripting dictionary. Read the front window title via Accessibility.
    /// Window title typically looks like: "Song — Artist — Amazon Music".
    private func amazonMusicTrack() -> String? {
        let script = """
            tell application "System Events"
                try
                    tell process "Amazon Music"
                        if (count of windows) > 0 then
                            return name of front window
                        end if
                    end tell
                end try
            end tell
            return ""
        """
        guard let raw = runAppleScript(script), !raw.isEmpty else { return nil }
        // Strip the trailing "Amazon Music" if present, return what's left.
        let cleaned = raw
            .replacingOccurrences(of: " - Amazon Music", with: "")
            .replacingOccurrences(of: " — Amazon Music", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let s = result.stringValue ?? ""
        return s.isEmpty ? nil : s
    }
}

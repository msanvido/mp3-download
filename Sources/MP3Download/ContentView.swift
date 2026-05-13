import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            header
            Divider()
            controls
            Divider()
            recordingsList
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            Image(systemName: statusIcon)
                .font(.system(size: 26))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.headline)
                if !state.currentTrackTitle.isEmpty {
                    Text(state.currentTrackTitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Output: \(state.outputDirectory.path)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Change…") { state.chooseOutputDirectory() }
            Button("Open Folder") { state.openOutputDir() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Source", selection: $state.selectedSourceID) {
                    ForEach(state.availableSources) { src in
                        Text(src.displayName).tag(src.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isRecording)
                Button {
                    state.refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRecording)
                .help("Refresh source list (run this after launching your streaming app)")
            }
            HStack(spacing: 12) {
                if isRecording {
                    Button(role: .destructive) { state.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.return)
                } else {
                    Button { state.start() } label: {
                        Label("Start Recording", systemImage: "record.circle.fill")
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                }

                LevelMeter(db: state.currentLevelDB)
                    .frame(height: 16)
                Text(state.currentLevelDB <= -120 ? "—— dB" : String(format: "%.0f dB", state.currentLevelDB))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)

                if isRecording, let s = state.trackStartString {
                    Text(s).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            HStack {
                Stepper(value: $state.silenceSplitSeconds, in: 0.4...5.0, step: 0.1) {
                    Text("Split after \(state.silenceSplitSeconds, specifier: "%.1f")s of silence")
                }
                .disabled(isRecording)
                Spacer()
            }
            HStack {
                Stepper(value: $state.streamEndSeconds, in: 5...120, step: 5) {
                    Text("Stop after \(Int(state.streamEndSeconds))s of silence")
                }
                .disabled(isRecording)
                Spacer()
            }
            HStack {
                Stepper(value: $state.silenceThresholdDB, in: -70 ... -20, step: 1) {
                    Text("Silence threshold: \(Int(state.silenceThresholdDB)) dBFS")
                }
                .disabled(isRecording)
                Spacer()
            }
        }
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recorded tracks (\(state.completedFiles.count))").font(.headline)
                Spacer()
                if !state.completedFiles.isEmpty {
                    Button {
                        state.identifyAll()
                    } label: {
                        Label("Identify all", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Identify all tracks via AudD.io and rename")
                }
            }
            if state.completedFiles.isEmpty {
                Text("Nothing yet — start playback in your streaming app and hit Start.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.completedFiles.reversed(), id: \.self) { url in
                            recordingRow(url)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            HStack(spacing: 6) {
                Text("AudD API key (optional):").font(.caption).foregroundStyle(.secondary)
                SecureField("free trial without key", text: $state.auddAPIKey, onCommit: state.saveAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 220)
                Spacer()
                Link("audd.io", destination: URL(string: "https://audd.io/")!)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func recordingRow(_ url: URL) -> some View {
        let identifying = state.identifyingFiles.contains(url)
        let errorMsg = state.identifyErrors[url]
        return HStack(spacing: 8) {
            Image(systemName: "music.note")
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let errorMsg {
                    Text(errorMsg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if identifying {
                ProgressView().scaleEffect(0.6)
            } else {
                Button("Identify") { state.identify(url) }.buttonStyle(.borderless).font(.callout)
            }
            Button("Reveal") { state.revealInFinder(url) }.buttonStyle(.borderless).font(.callout)
        }
        .padding(.vertical, 2)
    }

    private var isRecording: Bool {
        switch state.status {
        case .recording, .waitingForAudio: return true
        default: return false
        }
    }

    private var statusIcon: String {
        switch state.status {
        case .idle: return "circle"
        case .recording: return "record.circle.fill"
        case .waitingForAudio: return "ear.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .idle: return .secondary
        case .recording: return .red
        case .waitingForAudio: return .orange
        case .error: return .red
        }
    }

    private var statusText: String {
        switch state.status {
        case .idle: return "Idle"
        case .recording: return "Recording…"
        case .waitingForAudio: return "Waiting for audio…"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

private extension AppState {
    var trackStartString: String? {
        guard elapsedSeconds > 0 else { return nil }
        let s = Int(elapsedSeconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct LevelMeter: View {
    let db: Float
    var body: some View {
        GeometryReader { geo in
            let clamped = max(-60, min(0, db))
            let pct = CGFloat((clamped + 60) / 60)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * pct)
            }
        }
    }
}

import SwiftUI

struct MP3DownloadApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("MP3 Download") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 520, minHeight: 380)
        }
        .windowResizability(.contentSize)
    }
}

@main
struct Entry {
    static func main() {
        let args = CommandLine.arguments
        var mode = "app"
        if args.contains("--self-test") { mode = "self-test" }
        if args.contains("--auto-record") { mode = "auto-record" }
        let line = "[\(Date())] launched mode=\(mode) argv=\(args)\n"
        try? line.write(to: URL(fileURLWithPath: "/tmp/mp3download-launch.log"), atomically: false, encoding: .utf8)
        switch mode {
        case "self-test":
            SelfTest.run()
        case "auto-record":
            let secs: Double
            if let i = args.firstIndex(of: "--auto-record"), i + 1 < args.count, let d = Double(args[i+1]) {
                secs = d
            } else { secs = 12 }
            AutoRecord.run(durationSeconds: secs)
        default:
            MP3DownloadApp.main()
        }
    }
}

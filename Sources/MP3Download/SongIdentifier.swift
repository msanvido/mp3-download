import Foundation

/// Song recognition via AudD.io (https://audd.io).
/// Free trial works without an API key (limited per-day quota). Pass a token for higher quotas.
enum SongIdentifier {

    struct Match: Equatable {
        let artist: String
        let title: String
        var filename: String { "\(artist) - \(title)" }
    }

    enum IdentifyError: LocalizedError {
        case http(Int, String)
        case decode(String)
        case noMatch
        case quotaExceeded
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):    return "AudD HTTP \(code): \(body.prefix(120))"
            case .decode(let s):               return "AudD response parse error: \(s)"
            case .noMatch:                     return "Song not recognised"
            case .quotaExceeded:               return "AudD daily quota exceeded — set an API key in settings."
            case .transport(let e):            return "Network error: \(e.localizedDescription)"
            }
        }
    }

    /// POST the audio file to AudD and return the match (or nil if nothing was recognised).
    static func identify(audioURL: URL, apiKey: String?) async throws -> Match? {
        var request = URLRequest(url: URL(string: "https://api.audd.io/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let apiKey, !apiKey.isEmpty {
            addField("api_token", apiKey)
        }
        addField("return", "")  // keep response small — no Spotify/Apple Music lookups

        let fileData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw IdentifyError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw IdentifyError.http(0, "")
        }
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw IdentifyError.quotaExceeded }
            throw IdentifyError.http(http.statusCode, bodyString)
        }

        // AudD returns: { "status": "success", "result": { "artist": "...", "title": "..." } }
        //          or:  { "status": "success", "result": null }
        //          or:  { "status": "error",   "error":  { "error_code": N, "error_message": "..." } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IdentifyError.decode(bodyString.prefix(200).description)
        }
        if let err = json["error"] as? [String: Any] {
            let code = err["error_code"] as? Int ?? -1
            let msg = err["error_message"] as? String ?? "unknown"
            if code == 901 { throw IdentifyError.quotaExceeded }
            throw IdentifyError.http(code, msg)
        }
        guard let status = json["status"] as? String, status == "success" else {
            throw IdentifyError.decode("status != success: \(bodyString.prefix(200))")
        }
        guard let result = json["result"] as? [String: Any],
              let artist = result["artist"] as? String,
              let title = result["title"] as? String,
              !artist.isEmpty, !title.isEmpty else {
            return nil
        }
        return Match(artist: artist, title: title)
    }

    /// Rename `url` to `<newName>.mp3` in the same directory, avoiding overwriting existing files.
    static func rename(_ url: URL, toBaseName newName: String) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let safe = newName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var target = parent.appendingPathComponent("\(safe).mp3")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) && target != url {
            target = parent.appendingPathComponent("\(safe) (\(n)).mp3")
            n += 1
        }
        if target == url { return url }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

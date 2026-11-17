import Foundation

enum ClientError: LocalizedError {
    case status(Int, String)
    var errorDescription: String? {
        switch self { case .status(_, let why): return why }
    }
}

/// Talking to JARVIS on the Mac, over Tailscale: every request signed by the app's key.
enum Client {
    static func request(_ path: String, method: String = "GET", body: Data? = nil, type: String? = nil) throws -> URLRequest {
        guard let base = Pairing.shared.baseURL else { throw PairingError.refused("This app isn't paired with JARVIS.") }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 120
        if let type { req.setValue(type, forHTTPHeaderField: "Content-Type") }
        try Pairing.shared.sign(&req)
        return req
    }

    /// A request and its JSON answer, with the HTTP status.
    static func call(_ path: String, method: String = "GET", json: [String: Any]? = nil,
                     body: Data? = nil, type: String? = nil) async throws -> (Int, [String: Any]) {
        var data = body, contentType = type
        if let json { data = try JSONSerialization.data(withJSONObject: json); contentType = "application/json" }
        let req = try request(path, method: method, body: data, type: contentType)
        let (out, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:])
    }

    /// Asking: JARVIS's answer arrives line by line (its words, a spoken sentence as audio, which tool it used,
    /// and finally "done"), so it can be shown and spoken while the rest is still being written.
    /// `where` is the phone's position when the question needs it: sent as {"lat", "lon"}, or false when the phone
    /// couldn't or wouldn't say (JARVIS then tells him so), and left out when the question doesn't need it.
    static func ask(_ text: String, speak: Bool = true, where position: (lat: Double, lon: Double)?? = nil) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { go in
            let task = Task {
                do {
                    var fields: [String: Any] = ["text": text, "speak": speak]
                    if let asked = position {
                        fields["where"] = asked.map { ["lat": $0.lat, "lon": $0.lon] as Any } ?? false
                    }
                    let body = try JSONSerialization.data(withJSONObject: fields)
                    let req = try request("api/ask", method: "POST", body: body, type: "application/json")
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var raw = Data()
                        for try await b in bytes { raw.append(b) }
                        let j = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
                        throw ClientError.status(status, j?["error"] as? String ?? "JARVIS answered \(status).")
                    }
                    for try await line in bytes.lines {
                        if let d = line.data(using: .utf8),
                           let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                            go.yield(ev)
                        }
                    }
                    go.finish()
                } catch {
                    go.finish(throwing: error)
                }
            }
            go.onTermination = { _ in task.cancel() }
        }
    }
}

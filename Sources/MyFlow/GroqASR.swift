import Foundation

/// Groq-hosted Whisper (OpenAI-compatible endpoint). Used only as a hedge
/// when Cohere is slow, and only when GROQ_API_KEY is configured.
enum GroqASR {
    static func transcribe(wav: Data, key: String, language: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        let boundary = "MyFlow\(UUID().uuidString)"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "whisper-large-v3-turbo")
        field("response_format", "json")
        field("temperature", "0")
        if !language.isEmpty { field("language", language) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let megabytes = Double(wav.count) / 1_048_576
        req.timeoutInterval = min(60, max(15, 10 + megabytes * 10))

        let began = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw ServiceError.api("Groq \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        mflog(String(format: "Groq ASR ok: %.1fs round-trip", Date().timeIntervalSince(began)))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

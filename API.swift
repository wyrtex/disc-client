import Foundation

struct ProxySettings: Codable, Equatable {
    var enabled = false
    var host = "127.0.0.1"
    var port = 10808
    var socks = true
}

struct UploadFile: Identifiable {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data
}

enum APIError: LocalizedError {
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Некорректный ответ сервера"
        case .http(let code, let body): return "Ошибка \(code): \(body.prefix(200))"
        }
    }
}

extension Data {
    mutating func appendString(_ s: String) {
        append(Data(s.utf8))
    }
}

final class API {
    let token: String
    let session: URLSession

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init(token: String, proxy: ProxySettings) {
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        if proxy.enabled {
            if proxy.socks {
                cfg.connectionProxyDictionary = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": proxy.host,
                    "SOCKSPort": proxy.port
                ]
            } else {
                cfg.connectionProxyDictionary = [
                    "HTTPEnable": 1, "HTTPProxy": proxy.host, "HTTPPort": proxy.port,
                    "HTTPSEnable": 1, "HTTPSProxy": proxy.host, "HTTPSPort": proxy.port
                ]
            }
        }
        session = URLSession(configuration: cfg)
    }

    private func baseRequest(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = URL(string: "https://discord.com/api/v9" + path) else { throw APIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func check(_ data: Data, _ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func decodeResponse<T: Decodable>(_ data: Data, _ resp: URLResponse) throws -> T {
        try check(data, resp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        var req = try baseRequest(method, path)
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        return try decodeResponse(data, resp)
    }

    /// Запрос, у которого нет тела в ответе (реакции и т.п.).
    func noContent(_ method: String, _ path: String) async throws {
        let req = try baseRequest(method, path)
        let (data, resp) = try await session.data(for: req)
        try check(data, resp)
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await send("POST", path, body: body)
    }

    private func nonce() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    /// Голосовое сообщение: OGG/Opus загружается отдельно, потом уходит сообщение с флагом 8192.
    func sendVoiceMessage(channelId: String, ogg: Data, duration: Double, waveform: String, replyTo: String? = nil) async throws -> Message {
        struct Slot: Decodable {
            let upload_url: String
            let upload_filename: String
        }
        struct SlotList: Decodable {
            let attachments: [Slot]
        }

        let file: [String: Any] = ["filename": "voice-message.ogg", "file_size": ogg.count, "id": "2"]
        let slotBody: [String: Any] = ["files": [file]]
        let slots: SlotList = try await post("/channels/\(channelId)/attachments", body: slotBody)
        guard let slot = slots.attachments.first, let url = URL(string: slot.upload_url) else {
            throw APIError.badResponse
        }

        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("audio/ogg", forHTTPHeaderField: "Content-Type")
        let (putData, putResp) = try await session.upload(for: put, from: ogg)
        try check(putData, putResp)

        let attachment: [String: Any] = [
            "id": "0",
            "filename": "voice-message.ogg",
            "uploaded_filename": slot.upload_filename,
            "duration_secs": duration,
            "waveform": waveform
        ]
        var payload: [String: Any] = [
            "flags": 8192,
            "nonce": nonce(),
            "attachments": [attachment]
        ]
        if let replyTo {
            payload["message_reference"] = ["message_id": replyTo, "channel_id": channelId]
        }
        return try await post("/channels/\(channelId)/messages", body: payload)
    }

    /// Отправка сообщения: текст, ответ на сообщение, файлы (multipart).
    func sendMessage(channelId: String, content: String, files: [UploadFile], replyTo: String? = nil) async throws -> Message {
        let path = "/channels/\(channelId)/messages"
        var payload: [String: Any] = ["content": content, "nonce": nonce(), "tts": false]
        if let replyTo {
            payload["message_reference"] = ["message_id": replyTo, "channel_id": channelId]
        }
        if files.isEmpty {
            return try await post(path, body: payload)
        }

        var attachmentsJSON: [[String: Any]] = []
        for (i, f) in files.enumerated() {
            attachmentsJSON.append(["id": i, "filename": f.name])
        }
        payload["attachments"] = attachmentsJSON
        let json = try JSONSerialization.data(withJSONObject: payload)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"payload_json\"\r\n")
        body.appendString("Content-Type: application/json\r\n\r\n")
        body.append(json)
        body.appendString("\r\n")
        for (i, f) in files.enumerated() {
            let safeName = f.name.replacingOccurrences(of: "\"", with: "_")
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"files[\(i)]\"; filename=\"\(safeName)\"\r\n")
            body.appendString("Content-Type: \(f.mime)\r\n\r\n")
            body.append(f.data)
            body.appendString("\r\n")
        }
        body.appendString("--\(boundary)--\r\n")

        var req = try baseRequest("POST", path)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, from: body)
        return try decodeResponse(data, resp)
    }
}

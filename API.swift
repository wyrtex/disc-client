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

    /// Вызывается один раз, когда любой запрос получает 401 (токен умер) — чтобы Store
    /// автоматически запустил переполучение токена через веб-вход.
    var onUnauthorized: (() -> Void)?
    private var unauthorizedFired = false

    // UA настоящего десктоп-браузера. Discord к токену без согласованных заголовков клиента
    // относится как к «боту» и быстрее его аннулирует — поэтому выдаём себя за веб-клиент Chrome.
    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    private static let userAgent = browserUA

    /// X-Super-Properties: base64(JSON) с описанием клиента. Официальный веб-клиент шлёт его в
    /// КАЖДОМ запросе; без него сессия выглядит подозрительно и живёт недолго.
    private static let superProps: String = {
        let props: [String: Any] = [
            "os": "Mac OS X",
            "browser": "Chrome",
            "device": "",
            "system_locale": "en-US",
            "browser_user_agent": browserUA,
            "browser_version": "128.0.0.0",
            "os_version": "10.15.7",
            "referrer": "",
            "referring_domain": "",
            "referrer_current": "",
            "referring_domain_current": "",
            "release_channel": "stable",
            "client_build_number": 9999999,
            "client_event_source": NSNull()
        ]
        let data = (try? JSONSerialization.data(withJSONObject: props)) ?? Data()
        return data.base64EncodedString()
    }()

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
        // Заголовки настоящего веб-клиента — чтобы Discord не считал сессию ботом и не убивал токен.
        req.setValue(API.superProps, forHTTPHeaderField: "X-Super-Properties")
        req.setValue("en-US", forHTTPHeaderField: "X-Discord-Locale")
        req.setValue("bugReporterEnabled", forHTTPHeaderField: "X-Debug-Options")
        req.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        req.setValue("https://discord.com/channels/@me", forHTTPHeaderField: "Referer")
        return req
    }

    private func check(_ data: Data, _ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            // 401 = токен недействителен. Сообщаем наверх ровно один раз, чтобы запустить
            // авто-переполучение, и не спамим при каждом последующем запросе.
            if http.statusCode == 401, !unauthorizedFired {
                unauthorizedFired = true
                onUnauthorized?()
            }
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
    func noContent(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        var req = try baseRequest(method, path)
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        try check(data, resp)
    }

    /// Сырые данные ответа (чтобы сохранить их в кэш).
    func raw(_ path: String) async throws -> Data {
        let req = try baseRequest("GET", path)
        let (data, resp) = try await session.data(for: req)
        try check(data, resp)
        return data
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

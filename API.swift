import Foundation

struct ProxySettings: Codable, Equatable {
    var enabled = false
    var host = "127.0.0.1"
    var port = 10808
    var socks = true
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

final class API {
    let token: String
    let session: URLSession

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init(token: String, proxy: ProxySettings) {
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
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

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        guard let url = URL(string: "https://discord.com/api/v9" + path) else { throw APIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await send("POST", path, body: body)
    }
}

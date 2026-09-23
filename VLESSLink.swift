import Foundation

/// Один сервер VLESS+REALITY из подписки: адрес, ключи, человекочитаемое имя.
struct VLESSLink: Identifiable, Codable, Equatable {
    let id: String          // host:port — устойчивый идентификатор для хранения результатов и выбора
    let uuid: String
    let host: String
    let port: Int
    let flow: String        // обычно xtls-rprx-vision
    let sni: String         // под каким сайтом маскируется (REALITY)
    let publicKey: String   // pbk
    let shortId: String     // sid
    let fingerprint: String // fp, отпечаток TLS-клиента (firefox/chrome/safari…)
    let name: String        // название из ссылки после # (обычно "🇳🇱 Амстердам, Нидерланды, Extra")

    /// Короткое имя для списка: страна + город, без "Extra"/технических хвостов, если получится их узнать.
    var displayName: String {
        let cleaned = name
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "extra" }
        return cleaned.isEmpty ? host : cleaned.joined(separator: ", ")
    }
}

enum VLESSParser {
    /// Разбирает содержимое подписки: сама подписка — это base64 от списка ссылок `vless://...`,
    /// по одной на строке (стандартный формат V2Ray/Xray/sing-box подписок).
    static func parseSubscription(_ raw: String) -> [VLESSLink] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if let data = Data(base64Encoded: padded(trimmed)), let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            // Иногда отдают уже нормальный текст, без base64.
            text = trimmed
        }
        return text
            .components(separatedBy: .newlines)
            .compactMap { parseLink($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func padded(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let rem = clean.count % 4
        return rem == 0 ? clean : clean + String(repeating: "=", count: 4 - rem)
    }

    /// Разбирает одну ссылку `vless://uuid@host:port?...#name`.
    static func parseLink(_ s: String) -> VLESSLink? {
        guard s.hasPrefix("vless://"), let url = URL(string: s) else { return nil }
        guard let uuid = url.user, let host = url.host, let port = url.port else { return nil }

        var items: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            items[item.name] = item.value
        }
        guard items["security"] == "reality" else { return nil } // сейчас поддерживаем только REALITY
        guard let pbk = items["pbk"], let sid = items["sid"] else { return nil }

        let name = url.fragment.flatMap { $0.removingPercentEncoding } ?? "\(host):\(port)"
        return VLESSLink(
            id: "\(host):\(port)",
            uuid: uuid,
            host: host,
            port: port,
            flow: items["flow"] ?? "xtls-rprx-vision",
            sni: items["sni"] ?? host,
            publicKey: pbk,
            shortId: sid,
            fingerprint: items["fp"] ?? "chrome",
            name: name
        )
    }
}

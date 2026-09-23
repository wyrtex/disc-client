import Foundation

/// Собирает JSON-конфиг sing-box: локальный SOCKS5+HTTP прокси (inbound), а исходящий трафик
/// уходит на выбранный сервер по VLESS+REALITY (outbound). TUN/системный VPN не используется —
/// это просто локальный прокси внутри нашего же процесса, на него уже умеет указывать API.swift.
enum SingBoxConfig {
    static func build(link: VLESSLink, localPort: Int) -> String {
        let config: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "inbounds": [[
                "type": "mixed",
                "tag": "local-in",
                "listen": "127.0.0.1",
                "listen_port": localPort,
                "sniff": false
            ]],
            "outbounds": [[
                "type": "vless",
                "tag": "proxy",
                "server": link.host,
                "server_port": link.port,
                "uuid": link.uuid,
                "flow": link.flow,
                "packet_encoding": "xudp",
                "tls": [
                    "enabled": true,
                    "server_name": link.sni,
                    "utls": [
                        "enabled": true,
                        "fingerprint": link.fingerprint
                    ],
                    "reality": [
                        "enabled": true,
                        "public_key": link.publicKey,
                        "short_id": link.shortId
                    ]
                ]
            ]],
            "route": [
                "final": "proxy",
                "auto_detect_interface": true
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

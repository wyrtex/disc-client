import Foundation

/// Подключение к Discord Gateway для получения новых сообщений в реальном времени.
final class Gateway {
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var seq: Int?
    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false

    var onMessage: ((Message) -> Void)?
    /// Прочие события (сейчас только VOICE_*).
    var onEvent: ((String, [String: Any]) -> Void)?

    init(token: String, session: URLSession) {
        self.token = token
        self.session = session
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        heartbeatTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        guard let url = URL(string: "wss://gateway.discord.gg/?v=9&encoding=json") else { return }
        let t = session.webSocketTask(with: url)
        task = t
        seq = nil
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure:
                self.reconnect()
            case .success(let message):
                if case .string(let s) = message { self.handle(s) }
                self.receive(on: t)
            }
        }
    }

    private func reconnect() {
        guard !stopped else { return }
        heartbeatTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.stopped else { return }
            self.connect()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? Int else { return }
        if let s = obj["s"] as? Int { seq = s }

        switch op {
        case 10:
            let d = obj["d"] as? [String: Any]
            let interval = (d?["heartbeat_interval"] as? Double) ?? 41250
            startHeartbeat(interval: interval)
            identify()
        case 1:
            sendHeartbeat()
        case 7, 9:
            reconnect()
        case 0:
            let t = obj["t"] as? String ?? ""
            if t == "MESSAGE_CREATE",
               let d = obj["d"],
               let raw = try? JSONSerialization.data(withJSONObject: d),
               let msg = try? JSONDecoder().decode(Message.self, from: raw) {
                onMessage?(msg)
            } else if t.hasPrefix("VOICE_"), let d = obj["d"] as? [String: Any] {
                onEvent?(t, d)
            }
        default:
            break
        }
    }

    private func identify() {
        send([
            "op": 2,
            "d": [
                "token": token,
                "properties": ["os": "iOS", "browser": "Discord iOS", "device": "iPhone"],
                "presence": ["status": "online", "afk": false]
            ] as [String: Any]
        ])
    }

    private func startHeartbeat(interval: Double) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000))
                if Task.isCancelled { break }
                self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        let value: Any = seq.map { $0 as Any } ?? NSNull()
        send(["op": 1, "d": value])
    }

    /// Отправка произвольного пакета в основной Gateway (например, вход в голосовой канал).
    func sendRaw(_ obj: [String: Any]) {
        send(obj)
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }
}

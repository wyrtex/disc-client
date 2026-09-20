import Foundation

/// Подключение к Discord Gateway: новые сообщения и голосовые события в реальном времени.
/// Умеет восстанавливать сессию (resume), чтобы после сворачивания приложения не терять состояние.
final class Gateway {
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var seq: Int?
    private var sessionId: String?
    private var resumeURL: String?
    private var resuming = false
    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false
    private var retryDelay: Double = 3
    private var generation = 0
    private(set) var isReady = false

    var onMessage: ((Message) -> Void)?
    /// Голосовые события (VOICE_*).
    var onEvent: ((String, [String: Any]) -> Void)?
    /// Имя любого пришедшего события (для диагностики).
    var onDispatchName: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// Вызывается, когда шлюз готов (READY или RESUMED).
    var onReady: (() -> Void)?
    /// Голосовые состояния участников по серверам (из READY и GUILD_CREATE).
    var onGuildVoiceStates: (([(String, [[String: Any]])]) -> Void)?

    init(token: String, session: URLSession) {
        self.token = token
        self.session = session
    }

    private func log(_ s: String) { onLog?(s) }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        generation += 1
        heartbeatTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isReady = false
    }

    /// Проверка связи после возвращения в приложение.
    func ensureConnected() {
        guard !stopped else { return }
        guard let t = task else {
            generation += 1
            retryDelay = 3
            connect()
            return
        }
        t.sendPing { [weak self] err in
            if err != nil {
                self?.log("Gateway: связь потеряна, переподключаюсь")
                self?.reconnect(after: 0)
            }
        }
    }

    private func connect() {
        var urlString = "wss://gateway.discord.gg/?v=9&encoding=json"
        resuming = false
        if sessionId != nil, seq != nil, let base = resumeURL {
            urlString = base + "/?v=9&encoding=json"
            resuming = true
        }
        guard let url = URL(string: urlString) else { return }
        let t = session.webSocketTask(with: url)
        // Первое сообщение (READY) у пользовательского аккаунта на несколько мегабайт,
        // стандартный лимит iOS в 1 МБ обрывает соединение.
        t.maximumMessageSize = 64 * 1024 * 1024
        task = t
        if !resuming { seq = nil }
        isReady = false
        log(resuming ? "Gateway: подключаюсь (восстановление сессии)" : "Gateway: подключаюсь")
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure(let err):
                self.log("Gateway: соединение оборвалось (код \(t.closeCode.rawValue)): \(err.localizedDescription)")
                self.reconnect(after: nil)
            case .success(let message):
                if case .string(let s) = message { self.handle(s) }
                self.receive(on: t)
            }
        }
    }

    /// after == nil: пауза растёт от 3 до 60 секунд.
    private func reconnect(after fixed: Double?) {
        guard !stopped else { return }
        generation += 1
        let gen = generation
        heartbeatTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isReady = false

        let delay: Double
        if let fixed {
            delay = fixed
        } else {
            delay = retryDelay
            retryDelay = min(retryDelay * 2, 60)
        }
        log("Gateway: переподключение через \(Int(delay)) с")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.generation == gen else { return }
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
            if resuming {
                log("Gateway: Hello, восстанавливаю сессию")
                sendResume()
            } else {
                log("Gateway: Hello, отправляю Identify")
                identify()
            }
        case 1:
            sendHeartbeat()
        case 7:
            log("Gateway: сервер просит переподключиться (op 7)")
            reconnect(after: 1)
        case 9:
            log("Gateway: сессия недействительна (op 9), начинаю заново")
            sessionId = nil
            resumeURL = nil
            seq = nil
            reconnect(after: 2)
        case 0:
            let t = obj["t"] as? String ?? ""
            onDispatchName?(t)
            if t == "READY" {
                if let d = obj["d"] as? [String: Any] {
                    sessionId = d["session_id"] as? String
                    resumeURL = d["resume_gateway_url"] as? String
                    if let guilds = d["guilds"] as? [[String: Any]] {
                        emitVoiceStates(guilds)
                    }
                }
                isReady = true
                retryDelay = 3
                log("Gateway: READY получен (\(text.utf8.count / 1024) КБ)")
                onReady?()
            } else if t == "GUILD_CREATE", let d = obj["d"] as? [String: Any] {
                emitVoiceStates([d])
            } else if t == "RESUMED" {
                isReady = true
                retryDelay = 3
                log("Gateway: сессия восстановлена")
                onReady?()
            }
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

    private func emitVoiceStates(_ guilds: [[String: Any]]) {
        var out: [(String, [[String: Any]])] = []
        for g in guilds {
            if let id = g["id"] as? String,
               let vs = g["voice_states"] as? [[String: Any]],
               !vs.isEmpty {
                out.append((id, vs))
            }
        }
        if !out.isEmpty { onGuildVoiceStates?(out) }
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

    private func sendResume() {
        let d: [String: Any] = [
            "token": token,
            "session_id": sessionId ?? "",
            "seq": seq ?? 0
        ]
        send(["op": 6, "d": d])
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

    /// Отправка произвольного пакета (например, вход в голосовой канал). Возвращает false, если шлюз не подключён.
    @discardableResult
    func sendRaw(_ obj: [String: Any]) -> Bool {
        guard task != nil else {
            log("Gateway: не подключён, пакет не отправлен")
            return false
        }
        if !isReady { log("Gateway: готовность ещё не подтверждена, отправляю всё равно") }
        send(obj)
        return true
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }
}

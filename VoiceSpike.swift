import Foundation
import Network
import SwiftUI

// MARK: - Голосовой шлюз (диагностика)

/// Проходит по шагам подключения к голосовому серверу Discord и пишет всё в лог.
/// Звук пока не отправляется и не принимается, задача: выяснить, что именно требует Discord.
final class VoiceGateway {
    private let endpoint: String
    private let serverId: String
    private let userId: String
    private let sessionId: String
    private let token: String
    private let session: URLSession
    private let daveVersion: Int
    private let channelId: String
    private var dave: DaveSession?

    private var task: URLSessionWebSocketTask?
    private var seq: Int = -1
    private var heartbeatTask: Task<Void, Never>?
    private var udp: NWConnection?
    private var media: VoiceMedia?
    private var ssrcMap: [UInt32: String] = [:]
    private var userIds = Set<String>()

    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onUsers: (([String]) -> Void)?
    var onAudio: ((String) -> Void)?
    var onLocalSpeaking: ((Bool) -> Void)?
    var onMicLevel: ((Float) -> Void)?
    var vadThreshold: () -> Double = { -45 }
    var volumeForUser: ((String) -> Float)?

    var transcriber: VoiceTranscriber?
    private let videoProbe: Bool
    /// Соединение только для просмотра чужой демонстрации (отдельный сервер стрима).
    private let viewer: Bool
    var streamDisplay: StreamDisplay?
    var onFirstVideoFrame: (() -> Void)?
    /// true = это соединение отправляет НАШУ демонстрацию экрана.
    var broadcastSender = false
    private var screenStarted = false
    private var streamRx: StreamVideoReceiver?
    private var knownVideo: [UInt32: (user: String, rtx: UInt32?)] = [:]
    private let audio: VoiceAudio
    private let micAllowed: Bool
    private var ownSsrc: UInt32 = 0
    private var readyVideoSsrc: UInt32?
    private var readyVideoRtxSsrc: UInt32?
    private var videoSsrc: UInt32 = 0
    private var muted = false
    private var deafened = false

    init(endpoint: String, serverId: String, channelId: String, userId: String, sessionId: String, token: String,
         session: URLSession, daveVersion: Int, audio: VoiceAudio, micAllowed: Bool,
         muted: Bool, deafened: Bool, videoProbe: Bool, viewer: Bool = false) {
        self.videoProbe = videoProbe
        self.viewer = viewer
        self.channelId = channelId
        self.audio = audio
        self.micAllowed = micAllowed
        self.muted = muted
        self.deafened = deafened
        self.endpoint = endpoint
        self.serverId = serverId
        self.userId = userId
        self.sessionId = sessionId
        self.token = token
        self.session = session
        self.daveVersion = daveVersion
    }

    private func log(_ s: String) { onLog?(s) }

    func start() {
        var ep = endpoint
        if ep.hasSuffix(":443") { ep.removeLast(4) } else if ep.hasSuffix(":80") { ep.removeLast(3) }
        guard let url = URL(string: "wss://\(ep)/?v=8") else {
            log("Некорректный endpoint: \(endpoint)")
            return
        }
        if daveVersion > 0 {
            if let d = DaveSession(selfUserId: userId, channelId: channelId) {
                d.log = { [weak self] s in self?.log(s) }
                d.sendBinary = { [weak self] data in self?.task?.send(.data(data)) { _ in } }
                d.sendJSON = { [weak self] obj in self?.send(obj) }
                d.onEncryptionReady = { [weak self] _ in self?.onState?("Подключено, E2EE установлено") }
                dave = d
            } else {
                log("DAVE недоступна: библиотека не подключена к этой сборке")
            }
        }
        log("Voice WS: подключаюсь к \(ep)")
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        receive(on: t)
    }

    func setMuted(_ m: Bool) {
        muted = m
        media?.setMuted(m)
    }

    func setDeafened(_ d: Bool) {
        deafened = d
        audio.setDeafened(d)
    }

    func stop() {
        streamRx?.stop()
        streamRx = nil
        media?.stop()
        media = nil
        dave = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        udp?.cancel()
        udp = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure(let err):
                let code = t.closeCode.rawValue
                let reason = t.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.log("Voice WS закрыт. Код \(code) \(reason). \(VoiceGateway.explain(code)) (\(err.localizedDescription))")
                self.onState?("Ошибка")
            case .success(let message):
                switch message {
                case .string(let s):
                    self.handle(s)
                case .data(let d):
                    self.handleBinary(d)
                @unknown default:
                    break
                }
                self.receive(on: t)
            }
        }
    }

    private static func explain(_ code: Int) -> String {
        switch code {
        case 4001: return "Неизвестный опкод."
        case 4002: return "Не удалось разобрать пакет."
        case 4003: return "Нет авторизации."
        case 4004: return "Авторизация не прошла (токен)."
        case 4005: return "Уже авторизован."
        case 4006: return "Сессия недействительна."
        case 4009: return "Тайм-аут сессии."
        case 4011: return "Сервер не найден."
        case 4012: return "Неизвестный протокол."
        case 4014: return "Отключён (канал удалён или кикнули)."
        case 4015: return "Голосовой сервер упал."
        case 4016: return "Неизвестный режим шифрования."
        case 4017: return "Требуется E2EE-протокол DAVE."
        case 4020: return "Плохой запрос."
        case 4021: return "Превышен лимит запросов."
        case 4022: return "Звонок завершён."
        default: return ""
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? Int else { return }
        if let s = obj["seq"] as? Int { seq = s }
        let d = obj["d"] as? [String: Any] ?? [:]

        switch op {
        case 8:
            let interval = (d["heartbeat_interval"] as? Double) ?? 13750
            log("op 8 Hello, heartbeat \(Int(interval)) мс")
            startHeartbeat(interval)
            identify()
        case 6:
            break
        case 2:
            handleReady(d)
        case 4:
            handleSessionDescription(d)
        case 5:
            let uid = d["user_id"] as? String
            let ssrc = d["ssrc"] as? Int
            log("op 5 Speaking: \(uid ?? "?"), ssrc \(ssrc.map { String($0) } ?? "?"), флаги \(d["speaking"] as? Int ?? -1)")
            if let uid, let ssrc {
                let s = UInt32(truncatingIfNeeded: ssrc)
                ssrcMap[s] = uid
                media?.setSsrc(s, user: uid)
                audio.setVolume(volumeForUser?(uid) ?? 1, forUser: uid)
            }
        case 9:
            log("op 9 Resumed")
        case 11:
            let ids = d["user_ids"] as? [String] ?? []
            log("op 11: в канал вошли \(ids.joined(separator: ", "))")
            dave?.userConnected(ids)
            for id in ids { userIds.insert(id) }
            onUsers?(Array(userIds))
        case 13:
            if let id = d["user_id"] as? String {
                log("op 13: вышел \(id)")
                dave?.userDisconnected(id)
                userIds.remove(id)
                media?.removeUser(id)
                onUsers?(Array(userIds))
            }
        case 12:
            log("[видео/демо] Пришёл op 12 от сервера: \(d)")
            if let uid = d["user_id"] as? String {
                var ssrcs = Set<UInt32>()
                var rtxFor: [UInt32: UInt32] = [:]
                if let v = d["video_ssrc"] as? Int, v != 0 { ssrcs.insert(UInt32(truncatingIfNeeded: v)) }
                for s in (d["streams"] as? [[String: Any]]) ?? [] {
                    let active = (s["active"] as? Bool) ?? true
                    if active, let x = s["ssrc"] as? Int, x != 0 {
                        let primary = UInt32(truncatingIfNeeded: x)
                        ssrcs.insert(primary)
                        if let r = s["rtx_ssrc"] as? Int, r != 0 { rtxFor[primary] = UInt32(truncatingIfNeeded: r) }
                    }
                }
                for s in ssrcs {
                    let rtx = rtxFor[s] ?? (s &+ 1)
                    knownVideo[s] = (uid, rtx)
                    streamRx?.setVideo(ssrc: s, user: uid, rtx: rtx)
                }
                if viewer, !ssrcs.isEmpty {
                    var wants: [String: Any] = ["any": 100]
                    for s in ssrcs { wants[String(s)] = 100 }
                    send(["op": 15, "d": wants])
                    log("Демонстрация: запросил видео ssrc \(ssrcs.map(String.init).joined(separator: ", ")) в максимальном качестве")
                }
            }
        case 18, 20:
            log("op \(op): \(d)")
        case 21:
            let tid = d["transition_id"] as? Int ?? -1
            let ver = d["protocol_version"] as? Int ?? 0
            log("DAVE op 21 (prepare transition): id \(tid), версия \(ver)")
            dave?.onPrepareTransition(id: tid, version: ver)
        case 22:
            let tid = d["transition_id"] as? Int ?? -1
            log("DAVE op 22 (execute transition): id \(tid)")
            dave?.onExecuteTransition(id: tid)
        case 24:
            let ver = d["protocol_version"] as? Int ?? 0
            let epoch = (d["epoch"] as? Int) ?? Int((d["epoch"] as? String) ?? "") ?? -1
            log("DAVE op 24 (prepare epoch): эпоха \(epoch), версия \(ver)")
            dave?.onPrepareEpoch(epoch: epoch, version: ver)
        case 31:
            log("DAVE op 31: \(d)")
        default:
            log("op \(op): \(d)")
        }
    }

    private func identify() {
        let d: [String: Any] = [
            "server_id": serverId,
            "user_id": userId,
            "session_id": sessionId,
            "token": token,
            "max_dave_protocol_version": daveVersion,
            "video": true
        ]
        log("Отправляю Identify (op 0), DAVE v\(daveVersion), video: true")
        send(["op": 0, "d": d])
    }

    private func startHeartbeat(_ interval: Double) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000))
                if Task.isCancelled { break }
                guard let self else { break }
                let d: [String: Any] = [
                    "t": Int(Date().timeIntervalSince1970 * 1000),
                    "seq_ack": self.seq
                ]
                self.send(["op": 3, "d": d])
            }
        }
    }

    private func handleReady(_ d: [String: Any]) {
        let ssrc = (d["ssrc"] as? Int) ?? 0
        let ip = d["ip"] as? String ?? ""
        let port = (d["port"] as? Int) ?? 0
        let modes = d["modes"] as? [String] ?? []
        ownSsrc = UInt32(truncatingIfNeeded: ssrc)
        dave?.setSelfSsrc(ownSsrc)
        log("op 2 Ready: ssrc \(ssrc), UDP \(ip):\(port)")
        log("Режимы шифрования: \(modes.joined(separator: ", "))")
        // Discord может сразу выдать нам ssrc под видео (streams[0]); если нет — придумаем свой при старте камеры.
        if let streams = d["streams"] as? [[String: Any]], let first = streams.first {
            if let vs = first["ssrc"] as? Int { readyVideoSsrc = UInt32(truncatingIfNeeded: vs) }
            if let rtx = first["rtx_ssrc"] as? Int { readyVideoRtxSsrc = UInt32(truncatingIfNeeded: rtx) }
            log("Ready: Discord выдал ssrc для видео заранее: \(readyVideoSsrc.map(String.init) ?? "нет")")
        }
        // Видео-диагностика: печатаем Ready целиком — вдруг там есть данные о чужих потоках,
        // которые уже идут в канале на момент нашего входа (обычные поля ssrc/ip/port/modes уже разобраны выше).
        if videoProbe {
            log("[видео-диагностика] Ready целиком: \(d)")
        }
        discover(ip: ip, port: port, ssrc: UInt32(truncatingIfNeeded: ssrc), modes: modes)
    }

    private func discover(ip: String, port: Int, ssrc: UInt32, modes: [String]) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else {
            log("Некорректный UDP-порт")
            return
        }
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: p, using: params)
        udp = conn
        var finished = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var pkt = Data(count: 74)
                pkt[0] = 0x00
                pkt[1] = 0x01
                pkt[2] = 0x00
                pkt[3] = 0x46
                pkt[4] = UInt8((ssrc >> 24) & 0xFF)
                pkt[5] = UInt8((ssrc >> 16) & 0xFF)
                pkt[6] = UInt8((ssrc >> 8) & 0xFF)
                pkt[7] = UInt8(ssrc & 0xFF)
                conn.send(content: pkt, completion: .contentProcessed { _ in })
                conn.receiveMessage { data, _, _, error in
                    if finished { return }
                    finished = true
                    if let data, data.count >= 74 {
                        let addrBytes = data.subdata(in: 8..<72).prefix(while: { $0 != 0 })
                        let address = String(decoding: addrBytes, as: UTF8.self)
                        let pb = [UInt8](data.subdata(in: 72..<74))
                        let myPort = Int(pb[0]) << 8 | Int(pb[1])
                        self.log("UDP discovery: внешний адрес \(address):\(myPort)")
                        self.selectProtocol(address: address, port: myPort, modes: modes)
                    } else {
                        self.log("UDP: некорректный ответ. \(error?.localizedDescription ?? "")")
                    }
                }
            case .failed(let e):
                self.log("UDP: ошибка \(e)")
            case .waiting(let e):
                self.log("UDP: ожидание сети (\(e))")
            default:
                break
            }
        }
        conn.start(queue: .global())

        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in
            if !finished {
                finished = true
                self?.log("UDP: нет ответа за 6 секунд. UDP до Discord не проходит (VPN без UDP или блокировка).")
                self?.onState?("UDP не проходит")
            }
        }
    }

    private func selectProtocol(address: String, port: Int, modes: [String]) {
        let preferred = ["aead_aes256_gcm_rtpsize", "aead_xchacha20_poly1305_rtpsize"]
        let mode = preferred.first(where: { modes.contains($0) }) ?? modes.first ?? "aead_aes256_gcm_rtpsize"
        log("Выбираю режим шифрования: \(mode)")
        let data: [String: Any] = ["address": address, "port": port, "mode": mode]
        var d: [String: Any] = ["protocol": "udp", "data": data]
        // H264 на отправку (наша камера) всегда, плюс приём — если включена видео-диагностика.
        d["address"] = address
        d["port"] = port
        d["mode"] = mode
        d["codecs"] = [
            ["name": "opus", "type": "audio", "priority": 1000, "payload_type": 120],
            ["name": "H264", "type": "video", "priority": 1000, "payload_type": 101,
             "rtx_payload_type": 102, "encode": !viewer, "decode": videoProbe || viewer]
        ]
        d["experiments"] = [String]()
        send(["op": 1, "d": d])
    }

    private func handleSessionDescription(_ d: [String: Any]) {
        let mode = d["mode"] as? String ?? "?"
        let keyBytes = (d["secret_key"] as? [Int])?.map { UInt8(truncatingIfNeeded: $0) } ?? []
        let keyLen = keyBytes.count
        let daveVer = d["dave_protocol_version"] as? Int
        let daveText = daveVer.map { String($0) } ?? "нет"
        log("op 4 Session Description: режим \(mode), ключ \(keyLen) байт, DAVE: \(daveText)")
        log("Discord принял подключение.")
        if videoProbe {
            send(["op": 15, "d": ["any": 100]])
            log("Диагностика видео: отправил op 15 (желаемое качество)")
        }
        onState?("Подключено, обмен ключами DAVE…")
        if daveVersion > 0 {
            dave?.onSessionDescription(version: daveVer ?? 0)
        }

        if broadcastSender {
            // Мы отправляем экран: включаем видеопоток и начинаем слать кадры (их даёт VoiceSpike).
            startVideo()
            // Флаг «speaking» с битом 2 = идёт видео/демонстрация.
            send(["op": 5, "d": ["speaking": 2, "delay": 0, "ssrc": Int(ownSsrc)]])
            screenStarted = true
            onState?("В эфире")
            log("Отправка демонстрации запущена, ssrc \(videoSsrc)")
            return
        }
        if viewer {
            log("Демонстрация: кодек видео от сервера — \(d["video_codec"] ?? "не указан")")
            guard mode == "aead_aes256_gcm_rtpsize", keyBytes.count == 32, let conn = udp, let display = streamDisplay else {
                log("Демонстрация: режим \(mode) не поддерживается или нет UDP")
                return
            }
            let rx = StreamVideoReceiver(
                connection: conn,
                secretKey: Data(keyBytes),
                dave: daveVersion > 0 ? dave : nil,
                display: display,
                ownSsrc: ownSsrc
            )
            rx.log = { [weak self] s in self?.log(s) }
            rx.onFirstFrame = { [weak self] in self?.onFirstVideoFrame?() }
            for (ssrc, v) in knownVideo { rx.setVideo(ssrc: ssrc, user: v.user, rtx: v.rtx) }
            streamRx = rx
            rx.start()
            send(["op": 15, "d": ["any": 100]])
            onState?("Жду картинку…")
            log("Приём демонстрации запущен")
            return
        }

        if mode == "aead_aes256_gcm_rtpsize", keyBytes.count == 32, let conn = udp {
            let m = VoiceMedia(
                connection: conn,
                secretKey: Data(keyBytes),
                ssrc: ownSsrc,
                dave: daveVersion > 0 ? dave : nil,
                audio: audio,
                micAllowed: micAllowed
            )
            m.log = { [weak self] s in self?.log(s) }
            m.transcriber = transcriber
            m.ownUserId = userId
            m.onAudio = { [weak self] uid in self?.onAudio?(uid) }
            m.onLocalSpeaking = { [weak self] on in self?.onLocalSpeaking?(on) }
            m.onMicLevel = { [weak self] db in self?.onMicLevel?(db) }
            m.vadThresholdDb = { [weak self] in self?.vadThreshold() ?? -45 }
            m.sendSpeaking = { [weak self] on in
                guard let self else { return }
                let d: [String: Any] = ["speaking": on ? 1 : 0, "delay": 0, "ssrc": Int(self.ownSsrc)]
                self.send(["op": 5, "d": d])
            }
            for (ssrc, uid) in ssrcMap {
                m.setSsrc(ssrc, user: uid)
                audio.setVolume(volumeForUser?(uid) ?? 1, forUser: uid)
            }
            if let vs = readyVideoSsrc {
                videoSsrc = vs
                m.setVideoSsrc(vs)
            }
            m.videoPayloadType = 101
            m.setMuted(muted || deafened)
            audio.setDeafened(deafened)
            media = m
            m.start()
            log("Приём звука запущен (режим \(mode))")
        } else {
            log("Приём звука не запущен: режим \(mode) не поддерживается или нет UDP-соединения")
        }
    }

    /// Бинарные сообщения сервера: [seq (2 байта)] [opcode (1 байт)] [данные].
    private func handleBinary(_ d: Data) {
        guard d.count >= 3 else {
            log("Короткое бинарное сообщение: \(d.count) байт")
            return
        }
        seq = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
        let op = Int(d[d.startIndex + 2])
        let payload = Data(d.dropFirst(3))

        switch op {
        case 25:
            log("DAVE op 25 (внешний отправитель): \(payload.count) байт")
            dave?.onExternalSender(payload)
        case 27:
            log("DAVE op 27 (proposals): \(payload.count) байт")
            dave?.onProposals(payload)
        case 29, 30:
            guard payload.count >= 2 else {
                log("DAVE op \(op): слишком короткое сообщение")
                return
            }
            let tid = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
            let rest = Data(payload.dropFirst(2))
            if op == 29 {
                log("DAVE op 29 (commit): transition \(tid), \(rest.count) байт")
                dave?.onAnnounceCommit(id: tid, commit: rest)
            } else {
                log("DAVE op 30 (welcome): transition \(tid), \(rest.count) байт")
                dave?.onWelcome(id: tid, welcome: rest)
            }
        default:
            log("Бинарное сообщение op \(op), \(payload.count) байт")
        }
    }

    // MARK: Видео (камера)

    /// Включить свою камеру: придумываем ssrc (если Discord не выдал его заранее в Ready),
    /// регистрируем поток через op 12 и с этого момента пересылаем кадры в VoiceMedia.
    func startVideo() {
        if videoSsrc == 0 {
            videoSsrc = readyVideoSsrc ?? (ownSsrc &+ 1)
        }
        let rtxSsrc = readyVideoRtxSsrc ?? (videoSsrc &+ 1)
        media?.setVideoSsrc(videoSsrc)
        // Без этой привязки шифратор не знает про наш видео-ssrc и шифрование кадров с камеры
        // всегда проваливается — на телефоне видно было бы то же превью, но пусто у Discord.
        dave?.setSelfVideoSsrc(videoSsrc)
        let stream: [String: Any] = [
            "type": "video",
            "rid": "100",
            "quality": 100,
            "active": true,
            "ssrc": Int(videoSsrc),
            "rtx_ssrc": Int(rtxSsrc)
        ]
        let d: [String: Any] = [
            "audio_ssrc": Int(ownSsrc),
            "video_ssrc": Int(videoSsrc),
            "rtx_ssrc": Int(rtxSsrc),
            "streams": [stream]
        ]
        send(["op": 12, "d": d])
        log("Камера: включена, ssrc \(videoSsrc), отправил op 12")
    }

    func stopVideo() {
        guard videoSsrc != 0 else { return }
        let stream: [String: Any] = [
            "type": "video", "rid": "100", "quality": 100,
            "active": false, "ssrc": Int(videoSsrc), "rtx_ssrc": Int(readyVideoRtxSsrc ?? (videoSsrc &+ 1))
        ]
        let d: [String: Any] = [
            "audio_ssrc": Int(ownSsrc), "video_ssrc": Int(videoSsrc),
            "rtx_ssrc": Int(readyVideoRtxSsrc ?? (videoSsrc &+ 1)), "streams": [stream]
        ]
        send(["op": 12, "d": d])
        log("Камера: выключена")
    }

    func sendVideoFrame(nalUnits: [Data], timestamp: UInt32) {
        media?.sendVideoFrame(nalUnits: nalUnits, timestamp: timestamp)
    }

    /// Кадр экрана из расширения (уже H264). Пока не готов ключ шифрования — просто пропускаем.
    func sendScreenFrame(nalUnits: [Data], timestamp: UInt32) {
        guard screenStarted else { return }
        media?.sendVideoFrame(nalUnits: nalUnits, timestamp: timestamp)
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }
}


// MARK: - Управление голосовым подключением

/// Настройки, которые читаются из медиа-потока (не с главного потока).
final class VoiceSharedSettings {
    private let lock = NSLock()
    private var _vad: Double = -45

    var vad: Double {
        get { lock.lock(); defer { lock.unlock() }; return _vad }
        set { lock.lock(); _vad = newValue; lock.unlock() }
    }
}

struct VoiceFlags {
    var mute = false
    var deaf = false
    var video = false
    var stream = false
}

struct Caption: Identifiable {
    let id = UUID()
    var userId: String
    var text: String
    var isFinal: Bool
    var date: Date
    var lang: String?
    var translated: String?
}

struct TranscriptLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [TranscriptLanguage] = [
        TranscriptLanguage(code: "en-US", name: "English"),
        TranscriptLanguage(code: "ru-RU", name: "Русский"),
        TranscriptLanguage(code: "es-ES", name: "Español"),
        TranscriptLanguage(code: "pt-BR", name: "Português"),
        TranscriptLanguage(code: "fr-FR", name: "Français"),
        TranscriptLanguage(code: "de-DE", name: "Deutsch"),
        TranscriptLanguage(code: "it-IT", name: "Italiano"),
        TranscriptLanguage(code: "pl-PL", name: "Polski"),
        TranscriptLanguage(code: "tr-TR", name: "Türkçe"),
        TranscriptLanguage(code: "uk-UA", name: "Українська"),
        TranscriptLanguage(code: "ja-JP", name: "日本語"),
        TranscriptLanguage(code: "ko-KR", name: "한국어"),
        TranscriptLanguage(code: "zh-CN", name: "中文")
    ]
}

@MainActor
final class VoiceSpike: ObservableObject {
    @Published var log: [String] = []
    @Published var status = "Не подключено"
    @Published var activeChannelId: String?
    @Published var activeChannel: Channel?
    @Published var gwLog: [String] = []
    @Published var daveVersion = 1
    @Published var participantIds: [String] = []
    @Published var users: [String: User] = [:]
    @Published var flags: [String: VoiceFlags] = [:]
    @Published var muted = false
    @Published var deafened = false
    @Published var speakerOn = true
    @Published var videoOn = false
    @Published var cameraError: String?
    let camera = CameraSource()

    // Своя демонстрация экрана (Go Live через расширение трансляции).
    @Published var broadcasting = false
    @Published var broadcastStatus = ""
    @Published var blurOn = BroadcastShared.blur
    private let socketServer = LocalSocketServer()
    private var broadcastGateway: VoiceGateway?
    private var broadcastKey: String?
    private var broadcastRtc: String?
    private var broadcastEndpoint: String?
    private var broadcastToken: String?
    private var broadcastStartedObserver: NSObjectProtocol?
    private var broadcastStoppedObserver: NSObjectProtocol?
    private var recordingReadyObserver: NSObjectProtocol?
    private var frameClock: UInt32 = 0

    // Просмотр чужой демонстрации экрана (Go Live): отдельное соединение со своим сервером.
    @Published var watchingStream: String?
    @Published var streamStatus = ""
    let streamDisplay = StreamDisplay()
    private var streamKey: String?
    private var streamRtcServerId: String?
    private var streamEndpoint: String?
    private var streamToken: String?
    private var streamGateway: VoiceGateway?
    @Published var vadThreshold: Double = -45 {
        didSet { shared.vad = vadThreshold }
    }
    @Published var micLevelDb: Double = -90
    @Published var micAllowed = true
    @Published var encrypted = false
    @Published var captionsEnabled = false
    /// Языки, среди которых автоматически определяется речь.
    @Published var captionLangs: [String] = VoiceSpike.loadCaptionLangs() {
        didSet { UserDefaults.standard.set(captionLangs, forKey: "captionLangs") }
    }
    @Published var captionTranslate = UserDefaults.standard.bool(forKey: "captionTranslate") {
        didSet { UserDefaults.standard.set(captionTranslate, forKey: "captionTranslate") }
    }
    @Published var captionTarget = UserDefaults.standard.string(forKey: "captionTarget") ?? "ru" {
        didSet { UserDefaults.standard.set(captionTarget, forKey: "captionTarget") }
    }
    var translateCaption: ((String, String, String) async -> String?)?
    private var captionTasks: [UUID: Task<Void, Never>] = [:]

    nonisolated private static func loadCaptionLangs() -> [String] {
        if let saved = UserDefaults.standard.stringArray(forKey: "captionLangs"), !saved.isEmpty {
            return saved
        }
        var out = ["ru-RU", "en-US"]
        // Язык системы тоже включаем, если он есть в списке.
        let sys = Locale.preferredLanguages.first?.prefix(2) ?? ""
        if let l = TranscriptLanguage.all.first(where: { $0.code.hasPrefix(String(sys)) }), !out.contains(l.code) {
            out.append(l.code)
        }
        return out
    }
    @Published var captionStatus = ""
    @Published var captions: [Caption] = []
    @Published var captionsVersion = 0
    @Published var videoProbe = false
    @Published var stageTopic: String?
    @Published var stageSuppressed = true
    @Published var handRaised = false
    private var volumeCache: [String: Float] = [:]
    var patchVoiceState: ((String, [String: Any]) async -> Bool)?
    var fetchStageTopic: ((String) async -> String?)?

    let transcriber = VoiceTranscriber()

    init() {
        transcriber.onUpdate = { [weak self] u in
            Task { @MainActor in self?.handleTranscript(u) }
        }
        transcriber.onStatus = { [weak self] s in
            Task { @MainActor in self?.captionStatus = s }
        }
        setupCamera()
    }

    /// Когда последний раз слышали пользователя (читается из TimelineView, поэтому не @Published).
    var lastHeard: [String: Date] = [:]

    var sendGateway: (([String: Any]) -> Bool)?
    var ensureGateway: (() -> Void)?
    var resolveUser: ((String) async -> User?)?
    var cachedUser: ((String) -> User?)?
    var userId = ""
    var session: URLSession = .shared

    let audio = VoiceAudio()
    private let shared = VoiceSharedSettings()

    private var guildId: String?
    private var sessionId: String?
    private var server: (token: String, endpoint: String)?
    private var gateway: VoiceGateway?
    private var mutedBeforeDeafen = false

    private var awaitingLeave = false
    private var hasPendingLeave = false
    private var pendingLeaveGuild: String?
    private var leaveRetries = 0

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var isConnected: Bool { activeChannelId != nil }
    var activeGuildId: String? { guildId }
    var isStage: Bool { activeChannel?.type == 13 }

    // MARK: Лог

    func add(_ s: String) {
        log.append(VoiceSpike.timeFormatter.string(from: Date()) + "  " + s)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// Состояние основного шлюза (последние строки показываются в логе).
    func addGateway(_ s: String) {
        gwLog.append(VoiceSpike.timeFormatter.string(from: Date()) + "  " + s)
        if gwLog.count > 30 { gwLog.removeFirst(gwLog.count - 30) }
        if activeChannelId != nil { add(s) }
    }

    private static let noisyEvents: Set<String> = [
        "MESSAGE_CREATE", "MESSAGE_UPDATE", "MESSAGE_DELETE", "MESSAGE_ACK", "TYPING_START",
        "PRESENCE_UPDATE", "CHANNEL_UNREAD_UPDATE", "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE",
        "GUILD_MEMBER_UPDATE", "GUILD_MEMBER_LIST_UPDATE", "SESSIONS_REPLACE"
    ]

    func noteEvent(_ t: String) {
        guard activeChannelId != nil, !t.isEmpty, !VoiceSpike.noisyEvents.contains(t) else { return }
        add("Событие Gateway: \(t)")
    }

    // MARK: Участники

    func updateParticipants(_ others: [String]) {
        let ids = [userId] + others.filter { $0 != userId }.sorted()
        participantIds = ids
        for id in ids where users[id] == nil {
            if let u = cachedUser?(id) {
                users[id] = u
                continue
            }
            Task { [weak self] in
                if let u = await self?.resolveUser?(id) {
                    self?.users[id] = u
                }
            }
        }
    }

    func markHeard(_ uid: String) {
        lastHeard[uid] = Date()
    }

    // MARK: Вход и выход

    private func voiceStatePacket(guildId: String?, channelId: String?) -> [String: Any] {
        var d: [String: Any] = [
            "self_mute": muted || deafened,
            "self_deaf": deafened,
            "self_video": videoOn
        ]
        d["guild_id"] = guildId ?? NSNull()
        d["channel_id"] = channelId ?? NSNull()
        return ["op": 4, "d": d]
    }

    func join(guildId: String?, channel: Channel) {
        if activeChannelId == channel.id { return }
        leave(silent: true)
        log = []
        self.guildId = guildId
        sessionId = nil
        server = nil
        activeChannelId = channel.id
        activeChannel = channel
        status = "Подключаюсь…"
        encrypted = false
        flags = [:]
        lastHeard = [:]
        captions = []
        stageTopic = nil
        stageSuppressed = true
        handRaised = false
        updateParticipants([])
        ImageLoader.shared.setLimit(2)

        let cid = channel.id
        Task { [weak self] in
            guard let self else { return }
            self.micAllowed = await VoiceAudio.requestMicPermission()
            guard self.activeChannelId == cid else { return }
            if channel.type == 13 {
                self.stageTopic = await self.fetchStageTopic?(cid)
            }
            self.add(self.micAllowed ? "Микрофон: доступ есть" : "Микрофон: доступа нет, будет только прослушивание")
            self.add("Запрашиваю вход в канал (op 4), DAVE v\(self.daveVersion)")
            self.ensureGateway?()
            let sent = self.sendGateway?(self.voiceStatePacket(guildId: guildId, channelId: cid)) ?? false
            self.add(sent ? "op 4 отправлен" : "op 4 НЕ отправлен: основной шлюз не подключён")

            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.activeChannelId == cid, self.server == nil {
                self.add("За 8 секунд не пришло VOICE_SERVER_UPDATE. Discord не выдал голосовой сервер.")
                self.status = "Нет ответа от Discord"
            }
        }
    }

    private func setupCamera() {
        camera.onFrame = { [weak self] frame in
            self?.gateway?.sendVideoFrame(nalUnits: frame.nalUnits, timestamp: frame.timestamp)
        }
        camera.onError = { [weak self] msg in
            Task { @MainActor in self?.cameraError = msg }
        }
    }

        func leave(silent: Bool = false) {
        if broadcasting { stopBroadcast(notify: true) }
        if watchingStream != nil { stopWatching() }
        if videoOn {
            videoOn = false
            camera.stop()
        }
        gateway?.stop()
        gateway = nil
        if activeChannelId != nil {
            leaveRetries = 0
            sendLeave(guildId: guildId, silent: silent)
        }
        activeChannelId = nil
        activeChannel = nil
        status = "Не подключено"
        encrypted = false
        participantIds = []
        flags = [:]
        lastHeard = [:]
        micLevelDb = -90
        transcriber.reset()
        ImageLoader.shared.setLimit(6)
        if !silent { add("Отключился") }
    }

    /// Выход с подтверждением. Если шлюз мёртв, выход откладывается до восстановления связи.
    private func sendLeave(guildId: String?, silent: Bool) {
        ensureGateway?()
        let sent = sendGateway?(voiceStatePacket(guildId: guildId, channelId: nil)) ?? false
        if sent {
            awaitingLeave = true
            hasPendingLeave = false
            if !silent { add("op 4 (выход) отправлен, жду подтверждения от Discord") }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.awaitingLeave else { return }
                self.awaitingLeave = false
                if self.leaveRetries < 3 {
                    self.hasPendingLeave = true
                    self.pendingLeaveGuild = guildId
                    if !silent { self.add("Выход не подтверждён, повторю при восстановлении связи") }
                    self.ensureGateway?()
                }
            }
        } else {
            hasPendingLeave = true
            pendingLeaveGuild = guildId
            if !silent { add("Выход отложен: шлюз не подключён, отправлю при восстановлении связи") }
        }
    }

    func gatewayReady() {
        guard hasPendingLeave, leaveRetries < 3 else { return }
        leaveRetries += 1
        hasPendingLeave = false
        add("Связь восстановлена, повторяю выход из голосового канала")
        sendLeave(guildId: pendingLeaveGuild, silent: false)
    }

    // MARK: Субтитры

    func setCaptions(_ on: Bool) {
        if !on {
            captionsEnabled = false
            transcriber.configure(enabled: false, locales: captionLangs)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var ok = true
            if #available(iOS 26.0, *) {
                // Новое распознавание работает на устройстве и отдельного разрешения не требует.
            } else {
                ok = await VoiceTranscriber.requestAuthorization()
            }
            if ok {
                self.captionsEnabled = true
                self.transcriber.configure(enabled: true, locales: self.captionLangs)
            } else {
                self.captionsEnabled = false
                self.captionStatus = "Нет доступа к распознаванию речи. Разреши в Настройки → DiscClient."
            }
        }
    }

    /// Включить или выключить язык распознавания (при включении модель скачивается).
    func toggleCaptionLanguage(_ code: String) {
        if captionLangs.contains(code) {
            guard captionLangs.count > 1 else { return }
            captionLangs.removeAll { $0 == code }
        } else {
            captionLangs.append(code)
        }
        if captionsEnabled {
            transcriber.configure(enabled: true, locales: captionLangs)
        }
    }

    func handleTranscript(_ u: VoiceTranscriber.Update) {
        let id: UUID
        if let idx = captions.lastIndex(where: { $0.userId == u.userId }), !captions[idx].isFinal {
            captions[idx].text = u.text
            captions[idx].isFinal = u.isFinal
            captions[idx].date = Date()
            captions[idx].lang = u.lang
            id = captions[idx].id
        } else {
            let c = Caption(userId: u.userId, text: u.text, isFinal: u.isFinal, date: Date(), lang: u.lang, translated: nil)
            captions.append(c)
            id = c.id
        }
        if captions.count > 60 { captions.removeFirst(captions.count - 60) }
        captionsVersion += 1
        scheduleTranslation(id, text: u.text, lang: u.lang, final: u.isFinal)
    }

    /// Перевод строки субтитров: для черновика с небольшой задержкой, для итогового текста сразу.
    private func scheduleTranslation(_ id: UUID, text: String, lang: String?, final: Bool) {
        captionTasks[id]?.cancel()
        guard captionTranslate, let lang, let translate = translateCaption else { return }
        let src = SpeechLang.code(lang)
        let target = captionTarget
        if src == target || src.hasPrefix(target + "-") {
            if let i = captions.firstIndex(where: { $0.id == id }) { captions[i].translated = nil }
            return
        }
        captionTasks[id] = Task { [weak self] in
            if !final { try? await Task.sleep(nanoseconds: 900_000_000) }
            if Task.isCancelled { return }
            let tr = await translate(text, src, target)
            if Task.isCancelled { return }
            guard let self, let i = self.captions.firstIndex(where: { $0.id == id }) else { return }
            self.captions[i].translated = tr
            self.captionsVersion += 1
            if final { self.captionTasks[id] = nil }
        }
    }

    // MARK: Микрофон, наушники, маршрут звука

    /// Включить/выключить свою камеру. Сама съёмка и превью работают независимо от того,
    /// принял ли Discord поток — интерфейс не ждёт подтверждения.
    func toggleCamera() {
        guard isConnected else { return }
        if videoOn {
            videoOn = false
            camera.stop()
            gateway?.stopVideo()
            _ = sendGateway?(voiceStatePacket(guildId: guildId, channelId: activeChannelId))
            return
        }
        camera.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.cameraError = "Нет доступа к камере. Разреши в Настройки → DiscClient."
                return
            }
            self.videoOn = true
            self.camera.start()
            self.gateway?.startVideo()
            _ = self.sendGateway?(self.voiceStatePacket(guildId: self.guildId, channelId: self.activeChannelId))
        }
    }

    func flipCamera() {
        camera.flip()
    }

    func toggleMute() {
        if deafened {
            deafened = false
            muted = false
        } else {
            muted.toggle()
        }
        applyAudioState()
    }

    func toggleDeafen() {
        deafened.toggle()
        if deafened {
            mutedBeforeDeafen = muted
            muted = true
        } else {
            muted = mutedBeforeDeafen
        }
        applyAudioState()
    }

    private func applyAudioState() {
        gateway?.setMuted(muted || deafened || (isStage && stageSuppressed))
        gateway?.setDeafened(deafened)
        if userId.isEmpty == false {
            flags[userId] = VoiceFlags(mute: muted || deafened, deaf: deafened)
        }
        guard let cid = activeChannelId else { return }
        _ = sendGateway?(voiceStatePacket(guildId: guildId, channelId: cid))
    }

    // MARK: Громкость участников (только у тебя, не транслируется остальным)

    private static func volumeKey(_ user: String) -> String { "voiceVolume." + user }

    /// Текущая громкость участника (0…2). Читает сохранённое значение при первом обращении.
    func volume(for user: String) -> Float {
        if let v = volumeCache[user] { return v }
        let saved = UserDefaults.standard.object(forKey: VoiceSpike.volumeKey(user)) as? Float
        let v = saved ?? 1.0
        volumeCache[user] = v
        return v
    }

    /// Меняет громкость участника и запоминает выбор на будущее.
    func setVolume(_ v: Float, for user: String) {
        let clamped = max(0, min(2, v))
        volumeCache[user] = clamped
        UserDefaults.standard.set(clamped, forKey: VoiceSpike.volumeKey(user))
        audio.setVolume(clamped, forUser: user)
    }

    // MARK: Фон

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    /// Приложение свернули: держим голос. Фоновый режим «audio» оставляет приложение живым,
    /// а короткая фоновая задача страхует переход.
    func appDidEnterBackground() {
        guard isConnected else { return }
        endBackgroundTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "voice") { [weak self] in
            self?.endBackgroundTask()
        }
        audio.ensureRunning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func appDidBecomeActive() {
        endBackgroundTask()
        if isConnected { audio.ensureRunning() }
    }

    /// Слушатель трибуны не передаёт звук, пока его не позвали на сцену.
    private func refreshGatewayMute() {
        gateway?.setMuted(muted || deafened || (isStage && stageSuppressed))
    }

    // MARK: Трибуна

    private func patchStage(_ extra: [String: Any]) {
        guard isStage, let gid = guildId, let cid = activeChannelId else { return }
        var body: [String: Any] = ["channel_id": cid]
        for (k, v) in extra { body[k] = v }
        Task { [weak self] in
            let ok = await self?.patchVoiceState?(gid, body) ?? false
            if !ok { self?.add("Трибуна: Discord отклонил запрос") }
        }
    }

    /// Поднять или опустить руку («попросить слово»).
    func toggleHand() {
        let raise = !handRaised
        handRaised = raise
        let stamp: Any = raise ? ISO8601DateFormatter().string(from: Date()) : NSNull()
        patchStage(["request_to_speak_timestamp": stamp])
    }

    /// Выйти на сцену (нужны права модератора или приглашение).
    func becomeSpeaker() {
        patchStage(["suppress": false])
    }

    /// Вернуться в слушатели.
    func becomeListener() {
        patchStage(["suppress": true])
    }

    func setSpeaker(_ on: Bool) {
        speakerOn = on
        audio.speakerOn = on
        VoiceAudio.setSpeaker(on)
    }

    // MARK: События основного шлюза

    func handle(_ t: String, _ d: [String: Any]) {
        if t == "VOICE_STATE_UPDATE",
           (d["user_id"] as? String) == userId,
           (d["channel_id"] as? String) == nil,
           awaitingLeave {
            awaitingLeave = false
            hasPendingLeave = false
            add("Discord подтвердил выход из канала")
        }
        guard activeChannelId != nil else { return }
        switch t {
        case "VOICE_STATE_UPDATE":
            let uid = d["user_id"] as? String
            let channel = d["channel_id"] as? String
            if uid == userId, let sid = d["session_id"] as? String, channel != nil {
                sessionId = sid
                add("VOICE_STATE_UPDATE: получил session_id")
                tryConnect()
            }
            if uid == userId, channel == activeChannelId, isStage {
                let sup = d["suppress"] as? Bool ?? false
                let raised = (d["request_to_speak_timestamp"] as? String) != nil
                if sup != stageSuppressed || raised != handRaised {
                    stageSuppressed = sup
                    handRaised = raised
                    refreshGatewayMute()
                }
            }
            if let uid, channel == activeChannelId {
                let mute = (d["self_mute"] as? Bool ?? false) || (d["mute"] as? Bool ?? false)
                let deaf = (d["self_deaf"] as? Bool ?? false) || (d["deaf"] as? Bool ?? false)
                let video = d["self_video"] as? Bool ?? false
                let stream = d["self_stream"] as? Bool ?? false
                let prev = flags[uid]
                if video != (prev?.video ?? false) || stream != (prev?.stream ?? false) {
                    add("[видео/демо] \(uid): камера \(video ? "включена" : "выключена"), демонстрация \(stream ? "включена" : "выключена") — сырые данные: \(d)")
                }
                flags[uid] = VoiceFlags(
                    mute: mute,
                    deaf: deaf,
                    video: video,
                    stream: stream
                )
                if users[uid] == nil,
                   let member = d["member"] as? [String: Any],
                   let userObj = member["user"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: userObj),
                   let user = try? JSONDecoder().decode(User.self, from: data) {
                    users[uid] = user
                }
            }
        case "STREAM_CREATE", "STREAM_UPDATE":
            add("[видео/демо] \(t): \(d)")
            if let key = d["stream_key"] as? String, key == broadcastKey {
                if let rtc = d["rtc_server_id"] as? String { broadcastRtc = rtc }
                else if let rtc = d["rtc_server_id"] as? Int { broadcastRtc = String(rtc) }
                tryConnectBroadcast()
            }
            if let key = d["stream_key"] as? String, key == streamKey {
                if let rtc = d["rtc_server_id"] as? String {
                    streamRtcServerId = rtc
                } else if let rtc = d["rtc_server_id"] as? Int {
                    streamRtcServerId = String(rtc)
                }
                tryConnectStream()
            }
        case "STREAM_SERVER_UPDATE":
            add("[видео/демо] STREAM_SERVER_UPDATE: \(d["endpoint"] ?? "?")")
            if let key = d["stream_key"] as? String, key == broadcastKey,
               let token = d["token"] as? String, let ep = d["endpoint"] as? String {
                broadcastEndpoint = ep
                broadcastToken = token
                tryConnectBroadcast()
            }
            if let key = d["stream_key"] as? String, key == streamKey,
               let token = d["token"] as? String, let ep = d["endpoint"] as? String {
                streamEndpoint = ep
                streamToken = token
                tryConnectStream()
            }
        case "STREAM_DELETE":
            add("[видео/демо] STREAM_DELETE: \(d)")
            if let key = d["stream_key"] as? String, key == streamKey {
                let reason = d["reason"] as? String ?? ""
                stopWatching(notify: false)
                if reason == "stream_full" { add("Демонстрация: слишком много зрителей") }
            }
        case "VOICE_SERVER_UPDATE":
            if let token = d["token"] as? String, let ep = d["endpoint"] as? String {
                server = (token: token, endpoint: ep)
                add("VOICE_SERVER_UPDATE: \(ep)")
                tryConnect()
            } else {
                add("VOICE_SERVER_UPDATE без endpoint")
            }
        default:
            break
        }
    }

    // MARK: Просмотр демонстрации экрана

    /// Начать смотреть демонстрацию участника: просим у основного шлюза (op 20 Watch Stream)
    /// отдельный сервер стрима, дальше ждём STREAM_CREATE и STREAM_SERVER_UPDATE.
    // MARK: Своя демонстрация экрана

    /// Готовит настройки и слушает сокет от расширения. Само окно выбора "Общий экран" показывает
    /// системная кнопка трансляции — здесь мы только настраиваем качество/звук/блюр заранее.
    func prepareBroadcast(quality: BroadcastShared.Quality, streamAudio: Bool, blur: Bool, record: Bool) {
        BroadcastShared.defaults?.set(quality.rawValue, forKey: BroadcastShared.keyQuality)
        BroadcastShared.defaults?.set(streamAudio, forKey: BroadcastShared.keyStreamAudio)
        BroadcastShared.defaults?.set(blur, forKey: BroadcastShared.keyBlur)
        BroadcastShared.defaults?.set(record, forKey: BroadcastShared.keyRecord)
        blurOn = blur
        BroadcastShared.clearExtLog()
        setupBroadcastListeners()
        startExtLogPolling()
        add("[видео/демо] Демонстрация подготовлена: качество \(quality.rawValue), звук \(streamAudio), блюр \(blur), запись \(record)")
    }

    private func setupBroadcastListeners() {
        socketServer.onConnect = { [weak self] in
            Task { @MainActor in
                self?.add("[видео/демо] Расширение трансляции подключилось к приложению")
            }
        }
        socketServer.onFrame = { [weak self] type, payload in
            guard type == BroadcastWire.typeVideo else { return }
            Task { @MainActor in self?.forwardScreenFrame(payload) }
        }
        socketServer.start()

        if broadcastStartedObserver == nil {
            broadcastStartedObserver = BroadcastShared.observe(BroadcastShared.notifyStarted) { [weak self] in
                Task { @MainActor in self?.onBroadcastStarted() }
            }
        }
        if broadcastStoppedObserver == nil {
            broadcastStoppedObserver = BroadcastShared.observe(BroadcastShared.notifyStopped) { [weak self] in
                Task { @MainActor in self?.stopBroadcast(notify: true) }
            }
        }
        if recordingReadyObserver == nil {
            recordingReadyObserver = BroadcastShared.observe(BroadcastShared.notifyRecordingReady) { [weak self] in
                Task { @MainActor in self?.saveRecording() }
            }
        }
    }

    /// Расширение записало стрим в файл — сохраняем его в галерею.
    private func saveRecording() {
        guard let path = BroadcastShared.defaults?.string(forKey: BroadcastShared.keyLastRecording) else { return }
        let url = URL(fileURLWithPath: path)
        add("[видео/демо] Запись стрима готова, сохраняю в галерею")
        Task {
            do {
                try await MediaSaver.saveLocalVideo(url)
                await MainActor.run { self.add("[видео/демо] Запись сохранена в галерею") }
                try? FileManager.default.removeItem(at: url)
            } catch {
                await MainActor.run { self.add("[видео/демо] Не удалось сохранить запись: \(error.localizedDescription)") }
            }
        }
    }

    /// Пришёл сигнал, что системная трансляция реально стартовала — регистрируем стрим у Discord.
    private func onBroadcastStarted() {
        guard isConnected, !broadcasting, let cid = activeChannelId, let gid = guildId else { return }
        broadcasting = true
        broadcastStatus = "Запускаю демонстрацию…"
        broadcastKey = "guild:\(gid):\(cid):\(userId)"
        add("[видео/демо] Система начала запись экрана, отправляю op 18 (Stream Create)")
        _ = sendGateway?([
            "op": 18,
            "d": ["type": "guild", "guild_id": gid, "channel_id": cid, "preferred_region": NSNull()]
        ])
        // Снимаем возможную паузу.
        _ = sendGateway?(["op": 22, "d": ["stream_key": broadcastKey ?? "", "paused": false]])
    }

    func stopBroadcast(notify: Bool) {
        guard broadcasting || broadcastGateway != nil else { return }
        // Просим само расширение (захват экрана iOS) завершиться — иначе система продолжит писать экран.
        BroadcastShared.post(BroadcastShared.notifyStopCommand)
        if notify, let key = broadcastKey {
            _ = sendGateway?(["op": 18, "d": ["stream_key": key, "active": false]])
        }
        broadcastGateway?.stop()
        broadcastGateway = nil
        broadcasting = false
        broadcastStatus = ""
        broadcastKey = nil
        broadcastRtc = nil
        broadcastEndpoint = nil
        broadcastToken = nil
        flushExtLog()
        // Ещё раз через секунду — вдруг расширение допишет строку про причину остановки.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.flushExtLog() }
        extLogTimer?.invalidate()
        extLogTimer = nil
        add("[видео/демо] Демонстрация остановлена")
    }

    private var extLogTimer: Timer?
    private var extLogSeen = 0

    /// Периодически подтягиваем строки журнала расширения в наш экранный лог, чтобы видеть,
    /// на каком шаге расширение падает (оно пишет их в общий файл App Group).
    private func startExtLogPolling() {
        extLogSeen = 0
        extLogTimer?.invalidate()
        extLogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushExtLog() }
        }
    }

    private func flushExtLog() {
        let full = BroadcastShared.readExtLog()
        guard !full.isEmpty else { return }
        let lines = full.split(separator: "\n")
        if lines.count > extLogSeen {
            for line in lines[extLogSeen...] {
                add("[расширение] \(line)")
            }
            extLogSeen = lines.count
        }
    }

    func setBlur(_ on: Bool) {
        blurOn = on
        BroadcastShared.defaults?.set(on, forKey: BroadcastShared.keyBlur)
        BroadcastShared.post(on ? BroadcastShared.notifyBlurOn : BroadcastShared.notifyBlurOff)
        add("[видео/демо] Блюр экрана: \(on ? "включён" : "выключен")")
    }

    func toggleBlur() { setBlur(!blurOn) }

    /// Кадр экрана из расширения → в отправляющий шлюз демонстрации.
    private func forwardScreenFrame(_ annexb: Data) {
        guard let gw = broadcastGateway else { return }
        let nals = H264AnnexB.split(annexb)
        guard !nals.isEmpty else { return }
        // Таймштамп видео (90 кГц). Точная привязка не критична для приёмника.
        frameClock &+= 3000
        gw.sendScreenFrame(nalUnits: nals, timestamp: frameClock)
    }

    /// Подключение к серверу нашей демонстрации (получив STREAM_CREATE + STREAM_SERVER_UPDATE).
    private func tryConnectBroadcast() {
        guard broadcastGateway == nil, broadcasting,
              let rtc = broadcastRtc, let ep = broadcastEndpoint,
              let token = broadcastToken, let sid = sessionId,
              let rtcNum = UInt64(rtc), rtcNum > 0 else { return }
        add("[видео/демо] Подключаюсь к серверу СВОЕЙ демонстрации \(ep)")
        let vg = VoiceGateway(
            endpoint: ep, serverId: rtc, channelId: String(rtcNum - 1),
            userId: userId, sessionId: sid, token: token, session: session,
            daveVersion: daveVersion, audio: audio, micAllowed: false,
            muted: true, deafened: false, videoProbe: false, viewer: false
        )
        vg.broadcastSender = true
        vg.onLog = { [weak self] s in Task { @MainActor in self?.add("[стрим→] " + s) } }
        vg.onState = { [weak self] s in
            Task { @MainActor in
                guard let self, self.broadcasting else { return }
                self.broadcastStatus = s.contains("E2EE") ? "В эфире" : s
            }
        }
        broadcastGateway = vg
        vg.start()
    }

    func watchStream(_ uid: String) {
        guard isConnected, let cid = activeChannelId else { return }
        if watchingStream == uid { return }
        if watchingStream != nil { stopWatching() }
        let key: String
        if let gid = guildId {
            key = "guild:\(gid):\(cid):\(uid)"
        } else {
            key = "call:\(cid):\(uid)"
        }
        streamKey = key
        watchingStream = uid
        streamStatus = "Подключаюсь к демонстрации…"
        streamDisplay.reset()
        let sent = sendGateway?(["op": 20, "d": ["stream_key": key]]) ?? false
        add("[видео/демо] Прошу посмотреть демонстрацию (op 20), stream_key \(key)\(sent ? "" : " — НЕ отправлено, основной шлюз не подключён")")
    }

    func stopWatching(notify: Bool = true) {
        if notify, let key = streamKey {
            _ = sendGateway?(["op": 19, "d": ["stream_key": key]])
            add("[видео/демо] Перестал смотреть демонстрацию (op 19)")
        }
        streamGateway?.stop()
        streamGateway = nil
        streamKey = nil
        streamRtcServerId = nil
        streamEndpoint = nil
        streamToken = nil
        watchingStream = nil
        streamStatus = ""
        streamDisplay.reset()
    }

    private func tryConnectStream() {
        guard streamGateway == nil,
              let rtc = streamRtcServerId,
              let ep = streamEndpoint,
              let token = streamToken,
              let sid = sessionId else { return }
        // Группа MLS (DAVE) у стрима — это rtc_server_id минус один, а не id канала.
        guard let rtcNum = UInt64(rtc), rtcNum > 0 else {
            add("[видео/демо] Некорректный rtc_server_id: \(rtc)")
            return
        }
        add("[видео/демо] Подключаюсь к серверу демонстрации \(ep), rtc_server_id \(rtc)")
        let vg = VoiceGateway(
            endpoint: ep,
            serverId: rtc,
            channelId: String(rtcNum - 1),
            userId: userId,
            sessionId: sid,
            token: token,
            session: session,
            daveVersion: daveVersion,
            audio: audio,
            micAllowed: false,
            muted: true,
            deafened: false,
            videoProbe: true,
            viewer: true
        )
        vg.streamDisplay = streamDisplay
        vg.onLog = { [weak self] s in
            Task { @MainActor in self?.add("[стрим] " + s) }
        }
        vg.onState = { [weak self] s in
            Task { @MainActor in
                guard let self, self.watchingStream != nil, self.streamStatus != "" else { return }
                self.streamStatus = s.contains("E2EE") ? "Жду картинку…" : s
            }
        }
        vg.onFirstVideoFrame = { [weak self] in
            Task { @MainActor in self?.streamStatus = "" }
        }
        streamGateway = vg
        vg.start()
    }

    private func tryConnect() {
        guard gateway == nil,
              let sid = sessionId,
              let server,
              let channelId = activeChannelId else { return }
        audio.speakerOn = speakerOn
        let vg = VoiceGateway(
            endpoint: server.endpoint,
            serverId: guildId ?? channelId,
            channelId: channelId,
            userId: userId,
            sessionId: sid,
            token: server.token,
            session: session,
            daveVersion: daveVersion,
            audio: audio,
            micAllowed: micAllowed,
            muted: muted || (activeChannel?.type == 13 && stageSuppressed),
            deafened: deafened,
            videoProbe: videoProbe
        )
        vg.transcriber = transcriber
        let settings = shared
        vg.vadThreshold = { settings.vad }
        vg.volumeForUser = { [weak self] uid in self?.volume(for: uid) ?? 1 }
        vg.onLog = { [weak self] s in
            Task { @MainActor in self?.add(s) }
        }
        vg.onState = { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                self.status = s
                if s.contains("E2EE установлено") { self.encrypted = true }
            }
        }
        vg.onUsers = { [weak self] ids in
            Task { @MainActor in self?.updateParticipants(ids) }
        }
        vg.onAudio = { [weak self] uid in
            Task { @MainActor in self?.markHeard(uid) }
        }
        vg.onLocalSpeaking = { [weak self] on in
            Task { @MainActor in
                guard let self else { return }
                if on { self.markHeard(self.userId) } else { self.lastHeard[self.userId] = nil }
            }
        }
        vg.onMicLevel = { [weak self] db in
            Task { @MainActor in
                guard let self else { return }
                self.micLevelDb = Double(db)
                if self.micLevelDb > self.vadThreshold, !self.muted, !self.deafened {
                    self.markHeard(self.userId)
                }
            }
        }
        gateway = vg
        vg.start()
    }
}

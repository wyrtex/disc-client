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

    private var task: URLSessionWebSocketTask?
    private var seq: Int = -1
    private var heartbeatTask: Task<Void, Never>?
    private var udp: NWConnection?

    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?

    init(endpoint: String, serverId: String, userId: String, sessionId: String, token: String,
         session: URLSession, daveVersion: Int) {
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
        log("Voice WS: подключаюсь к \(ep)")
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        receive(on: t)
    }

    func stop() {
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
                    let op = d.count > 2 ? Int(d[2]) : -1
                    let head = d.prefix(12).map { String(format: "%02x", $0) }.joined()
                    self.log("Бинарное сообщение: \(d.count) байт, op \(op), начало \(head)")
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
            log("op 5 Speaking: \(d["user_id"] as? String ?? "?")")
        case 9:
            log("op 9 Resumed")
        case 11, 13, 18, 20:
            log("op \(op): \(d)")
        case 21, 22, 24, 31:
            log("DAVE op \(op): \(d)")
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
            "max_dave_protocol_version": daveVersion
        ]
        log("Отправляю Identify (op 0), DAVE v\(daveVersion)")
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
        log("op 2 Ready: ssrc \(ssrc), UDP \(ip):\(port)")
        log("Режимы шифрования: \(modes.joined(separator: ", "))")
        discover(ip: ip, port: port, ssrc: UInt32(truncatingIfNeeded: ssrc), modes: modes)
    }

    private func discover(ip: String, port: Int, ssrc: UInt32, modes: [String]) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else {
            log("Некорректный UDP-порт")
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: p, using: .udp)
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
        let d: [String: Any] = ["protocol": "udp", "data": data]
        send(["op": 1, "d": d])
    }

    private func handleSessionDescription(_ d: [String: Any]) {
        let mode = d["mode"] as? String ?? "?"
        let keyLen = (d["secret_key"] as? [Any])?.count ?? 0
        let dave = d["dave_protocol_version"] as? Int
        let daveText = dave.map { String($0) } ?? "нет"
        log("op 4 Session Description: режим \(mode), ключ \(keyLen) байт, DAVE: \(daveText)")
        log("ГОТОВО: Discord принял подключение.")
        onState?("Подключено (без звука)")
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }
}

// MARK: - Управление входом в канал

@MainActor
final class VoiceSpike: ObservableObject {
    @Published var log: [String] = []
    @Published var status = "Не подключено"
    @Published var activeChannelId: String?
    @Published var gwLog: [String] = []
    @Published var daveVersion = 1

    var sendGateway: (([String: Any]) -> Bool)?
    var ensureGateway: (() -> Void)?
    var userId = ""
    var session: URLSession = .shared

    private var guildId: String?
    private var sessionId: String?
    private var server: (token: String, endpoint: String)?
    private var gateway: VoiceGateway?

    private var awaitingLeave = false
    private var hasPendingLeave = false
    private var pendingLeaveGuild: String?
    private var leaveRetries = 0

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ s: String) {
        log.append(VoiceSpike.timeFormatter.string(from: Date()) + "  " + s)
    }

    /// Состояние основного шлюза (последние строки показываются на экране диагностики).
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

    /// Пока идёт подключение к каналу, пишем в лог названия приходящих событий.
    func noteEvent(_ t: String) {
        guard activeChannelId != nil, !t.isEmpty, !VoiceSpike.noisyEvents.contains(t) else { return }
        add("Событие Gateway: \(t)")
    }

    private func voiceStatePacket(guildId: String?, channelId: String?) -> [String: Any] {
        var d: [String: Any] = [
            "self_mute": true,
            "self_deaf": false,
            "self_video": false
        ]
        d["guild_id"] = guildId ?? NSNull()
        d["channel_id"] = channelId ?? NSNull()
        return ["op": 4, "d": d]
    }

    func join(guildId: String?, channelId: String) {
        leave(silent: true)
        log = []
        self.guildId = guildId
        sessionId = nil
        server = nil
        activeChannelId = channelId
        status = "Подключаюсь…"
        add("Запрашиваю вход в канал (op 4), DAVE v\(daveVersion)")
        ensureGateway?()
        let sent = sendGateway?(voiceStatePacket(guildId: guildId, channelId: channelId)) ?? false
        add(sent ? "op 4 отправлен" : "op 4 НЕ отправлен: основной шлюз не подключён")

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.activeChannelId == channelId, self.server == nil else { return }
            self.add("За 8 секунд не пришло VOICE_SERVER_UPDATE. Discord не выдал голосовой сервер.")
        }
    }

    func leave(silent: Bool = false) {
        gateway?.stop()
        gateway = nil
        if activeChannelId != nil {
            leaveRetries = 0
            sendLeave(guildId: guildId, silent: silent)
        }
        activeChannelId = nil
        status = "Не подключено"
        if !silent { add("Отключился") }
    }

    /// Выход из голосового канала с подтверждением. Если шлюз мёртв, выход откладывается до восстановления связи.
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

    /// Основной шлюз снова готов: досылаем отложенный выход.
    func gatewayReady() {
        guard hasPendingLeave, leaveRetries < 3 else { return }
        leaveRetries += 1
        hasPendingLeave = false
        add("Связь восстановлена, повторяю выход из голосового канала")
        sendLeave(guildId: pendingLeaveGuild, silent: false)
    }

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
            if (d["user_id"] as? String) == userId, let sid = d["session_id"] as? String,
               (d["channel_id"] as? String) != nil {
                sessionId = sid
                add("VOICE_STATE_UPDATE: получил session_id")
                tryConnect()
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

    private func tryConnect() {
        guard gateway == nil,
              let sid = sessionId,
              let server,
              let channelId = activeChannelId else { return }
        let vg = VoiceGateway(
            endpoint: server.endpoint,
            serverId: guildId ?? channelId,
            userId: userId,
            sessionId: sid,
            token: server.token,
            session: session,
            daveVersion: daveVersion
        )
        vg.onLog = { [weak self] s in
            Task { @MainActor in self?.add(s) }
        }
        vg.onState = { [weak self] s in
            Task { @MainActor in self?.status = s }
        }
        gateway = vg
        vg.start()
    }
}

// MARK: - Экран диагностики

struct VoiceDebugView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var voice: VoiceSpike
    let channel: Channel
    let guildId: String?

    private var isActive: Bool { voice.activeChannelId == channel.id }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: channel.icon)
                    .foregroundStyle(Theme.muted)
                Text(channel.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(voice.status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

            Text("Диагностика подключения к голосу. Звука пока нет. Ты появишься в списке участников канала, лучше проверять на своём сервере. При закрытии экрана приложение выйдет из канала.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                voice.add("DAVE в сборке: \(DaveLib.isBuiltIn ? "да" : "нет")")
                for line in DaveLib.selfTest() { voice.add(line) }
            } label: {
                Text("Проверить библиотеку DAVE")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.input, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Theme.text)
            }

            Picker("DAVE", selection: $voice.daveVersion) {
                Text("DAVE 0 (без E2EE)").tag(0)
                Text("DAVE 1 (заявить поддержку)").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(isActive)

            if !voice.gwLog.isEmpty {
                Text("Основной шлюз:\n" + voice.gwLog.suffix(3).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(voice.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.normalText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .background(Theme.rail, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: voice.log.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }

            HStack(spacing: 10) {
                Button {
                    if isActive {
                        voice.leave()
                    } else {
                        voice.join(guildId: guildId ?? channel.guild_id, channelId: channel.id)
                    }
                } label: {
                    Text(isActive ? "Отключиться" : "Подключиться")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isActive ? Color.red : Theme.blurple, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                Button {
                    UIPasteboard.general.string = voice.log.joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 46, height: 46)
                        .background(Theme.input, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .padding(16)
        .background(Theme.panel)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
        .onDisappear {
            if isActive { voice.leave() }
        }
    }
}

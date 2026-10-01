import SwiftUI
import UIKit
import Network

// MARK: - HTTP через сокет (обход ATS)

/// Минимальный HTTP-клиент поверх Network.framework. Нужен, чтобы ходить на сервер по http://
/// без HTTPS: ATS в iOS действует только на URLSession, а на NWConnection — нет.
enum RawHTTP {
    struct Response { let status: Int; let body: Data }
    enum RawError: LocalizedError {
        case badURL, failed(String), timeout
        var errorDescription: String? {
            switch self {
            case .badURL: return "неверный адрес"
            case .failed(let s): return s
            case .timeout: return "сервер не ответил (таймаут)"
            }
        }
    }

    static func request(method: String, urlString: String,
                        headers: [String: String] = [:], body: Data? = nil,
                        timeout: TimeInterval = 10) async throws -> Response {
        guard let url = URL(string: urlString), let host = url.host else { throw RawError.badURL }
        let port = UInt16(url.port ?? 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?\(q)" }

        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var packet = Data(head.utf8)
        if let body { packet.append(body) }

        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 80,
                                using: .tcp)

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            var received = Data()
            func finish(_ r: Result<Response, Error>) {
                if finished { return }
                finished = true
                conn.cancel()
                cont.resume(with: r)
            }
            func receiveLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, isComplete, err in
                    if let chunk { received.append(chunk) }
                    if let err { finish(.failure(RawError.failed("\(err)"))); return }
                    if isComplete { finish(.success(parse(received))); return }
                    receiveLoop()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: packet, completion: .contentProcessed { sendErr in
                        if let sendErr { finish(.failure(RawError.failed("\(sendErr)"))); return }
                        receiveLoop()
                    })
                case .failed(let e): finish(.failure(RawError.failed("\(e)")))
                case .waiting(let e): finish(.failure(RawError.failed("\(e)")))
                default: break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(RawError.timeout)) }
            conn.start(queue: .global())
        }
    }

    private static func parse(_ data: Data) -> Response {
        guard let r = data.range(of: Data("\r\n\r\n".utf8)) else { return Response(status: 0, body: data) }
        let headerStr = String(data: data[..<r.lowerBound], encoding: .utf8) ?? ""
        var status = 0
        if let line = headerStr.split(separator: "\r\n").first {
            let parts = line.split(separator: " ")
            if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
        }
        return Response(status: status, body: Data(data[r.upperBound...]))
    }
}

// MARK: - Конфигурация скриптов (хранится в UserDefaults)

struct ScriptsConfig: Codable, Equatable {
    var autoEnabled = false
    var autoGuildId: String?
    var autoChannelIds: [String] = []
    var autoMessages = ""            // каждая строка — отдельный вариант сообщения

    var aiEnabled = false
    var aiGuildId: String?
    var aiChannelIds: [String] = []

    // Сервер 24/7: если адрес задан, скрипты крутятся на сервере, а приложение только шлёт ему
    // конфиг (включает/выключает удалённо). Локально при этом ничего не запускается.
    // Заполнено по умолчанию, чтобы не вводить вручную (можно поменять в настройках).
    var serverURL = "http://195.14.118.91:8787"
    var serverSecret = "12345"
}

// MARK: - Движок скриптов

/// Выполняет два фоновых скрипта, пока приложение открыто:
/// 1) Автосообщения — шлёт случайное сообщение из списка в выбранные чаты и сразу удаляет.
///    Пауза на час, если кто-то зашёл в войс или написал в наблюдаемый чат.
/// 2) ИИ-бот — анализирует чат и отвечает в его стиле, поддерживая диалог.
@MainActor
final class ScriptsEngine: ObservableObject {
    @Published var config = ScriptsConfig() { didSet { persist() } }
    /// Что происходит с автосообщениями (виден в настройках для диагностики).
    @Published var autoLog = "не запущено"
    /// Результат последней синхронизации с сервером.
    @Published var serverStatus = ""
    weak var store: Store?

    private let key = "scriptsConfig"
    private var autoTask: Task<Void, Never>?
    private var autoPausedUntil = Date.distantPast
    private var aiCooldown: [String: Date] = [:]
    private var aiPending: [String: Task<Void, Never>] = [:]

    /// Управляем сервером, а не крутим скрипты локально.
    private var usingServer: Bool { !config.serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    init() { load() }

    // Хранилище
    private func load() {
        if let d = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode(ScriptsConfig.self, from: d) {
            config = c
        }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(config) { UserDefaults.standard.set(d, forKey: key) }
        restartAuto()
        if usingServer { pushToServer() }
    }

    func start() { restartAuto() }

    // MARK: Сервер 24/7

    /// Отправляет текущий конфиг на сервер (он включает/выключает скрипты у себя).
    func pushToServer() {
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let payload: [String: Any] = [
            "autoEnabled": config.autoEnabled,
            "autoChannelIds": config.autoChannelIds,
            "autoMessages": config.autoMessages,
            "aiEnabled": config.aiEnabled,
            "aiChannelIds": config.aiChannelIds
        ]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        let secret = config.serverSecret
        Task { @MainActor in
            do {
                let r = try await RawHTTP.request(
                    method: "POST", urlString: "\(base)/config",
                    headers: ["Content-Type": "application/json", "X-Auth": secret],
                    body: body)
                serverStatus = r.status == 200 ? "конфиг отправлен на сервер ✓" : "сервер ответил \(r.status)"
            } catch {
                serverStatus = "нет связи с сервером: \(error.localizedDescription)"
            }
        }
    }

    /// Проверка связи с сервером (GET /status).
    func checkServer() {
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let secret = config.serverSecret
        Task { @MainActor in
            do {
                let r = try await RawHTTP.request(
                    method: "GET", urlString: "\(base)/status",
                    headers: ["X-Auth": secret])
                if r.status == 200,
                   let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] {
                    let user = (obj["user"] as? String) ?? "не залогинен"
                    serverStatus = "сервер на связи, аккаунт: \(user)"
                } else {
                    serverStatus = "сервер ответил \(r.status)"
                }
            } catch {
                serverStatus = "нет связи с сервером: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Автосообщения

    private func restartAuto() {
        autoTask?.cancel()
        autoTask = nil
        if usingServer { autoLog = "управляется сервером"; return }   // локально не крутим
        guard config.autoEnabled else { autoLog = "выключено"; return }
        autoLog = "запущено, первое сообщение через ~10 c"
        autoTask = Task { [weak self] in
            // Первый тик быстро (для проверки), дальше — раз в 1–3 минуты.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while !Task.isCancelled {
                await self?.tickAuto()
                let delay = Double.random(in: 60...180)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func tickAuto() async {
        guard config.autoEnabled else { return }
        if Date() < autoPausedUntil {
            autoLog = "на паузе (активность в чате/войсе)"
            return
        }
        guard let api = store?.api else { autoLog = "нет соединения (api)"; return }
        let lines = config.autoMessages
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { autoLog = "список сообщений пуст"; return }
        guard let cid = config.autoChannelIds.randomElement() else { autoLog = "не выбраны чаты"; return }
        guard let text = lines.randomElement() else { return }
        do {
            let sent = try await api.sendMessage(channelId: cid, content: text, files: [], replyTo: nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await api.noContent("DELETE", "/channels/\(cid)/messages/\(sent.id)")
            autoLog = "отправлено и удалено: «\(text.prefix(30))»"
        } catch {
            autoLog = "ошибка отправки: \(error.localizedDescription)"
        }
    }

    // MARK: Триггеры от Gateway

    /// Новое сообщение в канале (из Store.onMessage).
    func onMessage(_ msg: Message) {
        if usingServer { return }   // всё делает сервер
        guard let meId = store?.me?.id, msg.author.id != meId else { return }
        if config.autoEnabled, config.autoChannelIds.contains(msg.channel_id) {
            autoPausedUntil = Date().addingTimeInterval(3600)   // кто-то написал — пауза на час
        }
        if config.aiEnabled, config.aiChannelIds.contains(msg.channel_id), !(msg.author.bot ?? false) {
            scheduleAI(channelId: msg.channel_id)
        }
    }

    /// Кто-то появился в войсе (из Store.applyVoiceStateUpdate).
    func onVoiceActivity(guildId: String, userId: String, joined: Bool) {
        guard joined, let meId = store?.me?.id, userId != meId else { return }
        if config.autoEnabled, config.autoGuildId == guildId {
            autoPausedUntil = Date().addingTimeInterval(3600)
        }
    }

    // MARK: ИИ-бот

    /// Единый промпт ИИ-бота (используется и в приложении, и на сервере — держим одинаковым).
    static func aiPrompt(transcript: String) -> String {
        """
        Ты — участник чата Discord и пишешь от первого лица, как обычный собеседник, а НЕ бот.
        Сначала проанализируй, как в этом чате общаются: язык, тон, длина сообщений, сленг, пунктуация, регистр букв. Ответь ТОЧНО в этом же стиле.

        Правила:
        - Если у тебя уже идёт диалог с кем-то — поддерживай его, отвечай по теме.
        - Если зашла тема, которую ты не знаешь — не выдумывай: ответь, что не в курсе, но в стиле чата (например «i wouldn't say that tbh», «хз чёт не шарю»). На языке чата.
        - Если хочешь сам вставить что-то в разговор (не в ответ кому-то) — сначала подумай, уместно ли это сейчас. Если не уместно или не уверен — верни пустую строку и промолчи.
        - Не спорь с людьми — они знают лучше. Поддерживай и соглашайся.
        - Никаких своих шуток, сарказма, подколов, лишних эмодзи.
        - Пиши коротко и естественно, как принято в этом чате, на языке чата.
        - Не представляйся, не упоминай что ты ИИ, не объясняй свои действия.

        Верни ТОЛЬКО текст ответа (одно сообщение) или пустую строку, если отвечать не стоит.

        Чат:
        \(transcript)
        """
    }

    private func scheduleAI(channelId: String) {
        if let next = aiCooldown[channelId], Date() < next { return }
        aiPending[channelId]?.cancel()
        aiPending[channelId] = Task { [weak self] in
            // Небольшая пауза: вдруг человек допишет ещё сообщения — ответим на всё сразу.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            await self?.respondAI(channelId: channelId)
        }
    }

    private func respondAI(channelId: String) async {
        guard config.aiEnabled, let store, let api = store.api, let meId = store.me?.id else { return }

        var msgs = store.messages[channelId] ?? []
        if msgs.count < 6, let fetched: [Message] = try? await api.get("/channels/\(channelId)/messages?limit=40") {
            msgs = fetched.reversed()
        }
        let recent = Array(msgs.suffix(40))
        guard let last = recent.last, last.author.id != meId else { return }   // не отвечаем на своё же

        let transcript = recent.map { m -> String in
            let name = store.guildNick(guildId: config.aiGuildId, user: m.author, fallbackNick: m.member_nick)
            let body = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name): \(body.isEmpty ? "[вложение]" : body)"
        }.joined(separator: "\n")

        let prompt = ScriptsEngine.aiPrompt(transcript: transcript)

        guard let reply = try? await GeminiClient.generateText(prompt: prompt, temperature: 0.7) else { return }
        let clean = reply.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\"'"))
        guard !clean.isEmpty, clean.count <= 500 else { return }
        aiCooldown[channelId] = Date().addingTimeInterval(45)
        _ = try? await api.sendMessage(channelId: channelId, content: clean, files: [], replyTo: nil)
    }
}

// MARK: - Экран «Скрипты»

struct ScriptsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var engine: ScriptsEngine
    @Environment(\.dismiss) private var dismiss
    @State private var setupAuto = false
    @State private var setupAI = false
    @State private var tokenCopied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let token = Keychain.load() ?? ""
                    Button {
                        UIPasteboard.general.string = token
                        tokenCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tokenCopied = false }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tokenCopied ? "Скопировано ✓" : "Токен Discord (нажми, чтобы скопировать)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(tokenCopied ? Theme.green : Theme.link)
                                Text(token.isEmpty ? "нет токена" : token)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(Theme.link)
                        }
                    }
                } header: {
                    Text("Токен")
                } footer: {
                    Text("Нужен для .env на сервере (DISCORD_TOKEN). Никому не показывай — это полный доступ к аккаунту.")
                }

                Section {
                    Toggle("Автосообщения", isOn: Binding(
                        get: { engine.config.autoEnabled },
                        set: { on in
                            engine.config.autoEnabled = on
                            if on, engine.config.autoChannelIds.isEmpty { setupAuto = true }
                        }
                    ))
                    if engine.config.autoEnabled {
                        Button("Настроить") { setupAuto = true }
                            .foregroundStyle(Theme.link)
                        summary(guildId: engine.config.autoGuildId,
                                channels: engine.config.autoChannelIds,
                                extra: "Вариантов: \(messageLineCount)")
                        Text("Статус: \(engine.autoLog)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Автосообщения")
                } footer: {
                    Text("Пишет случайное сообщение из списка в выбранные чаты и сразу удаляет его. Останавливается на час, если кто-то зашёл в войс или написал в наблюдаемый чат.")
                }

                Section {
                    Toggle("ИИ-бот", isOn: Binding(
                        get: { engine.config.aiEnabled },
                        set: { on in
                            engine.config.aiEnabled = on
                            if on, engine.config.aiChannelIds.isEmpty { setupAI = true }
                        }
                    ))
                    if engine.config.aiEnabled {
                        Button("Настроить") { setupAI = true }
                            .foregroundStyle(Theme.link)
                        summary(guildId: engine.config.aiGuildId,
                                channels: engine.config.aiChannelIds,
                                extra: nil)
                    }
                } header: {
                    Text("ИИ-бот")
                } footer: {
                    Text("Анализирует чат, понимает тему и отвечает в том же стиле, поддерживая разговор. Не спорит и не шутит.")
                }

                Section {
                    TextField("http://адрес:порт", text: Binding(
                        get: { engine.config.serverURL }, set: { engine.config.serverURL = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Секрет (X-Auth)", text: Binding(
                        get: { engine.config.serverSecret }, set: { engine.config.serverSecret = $0 }))
                    HStack {
                        Button("Проверить связь") { engine.checkServer() }
                            .foregroundStyle(Theme.link)
                        Spacer()
                        Button("Отправить конфиг") { engine.pushToServer() }
                            .foregroundStyle(Theme.link)
                    }
                    if !engine.serverStatus.isEmpty {
                        Text(engine.serverStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Сервер 24/7")
                } footer: {
                    Text("Если задать адрес сервера, скрипты работают на нём постоянно (даже когда телефон выключен), а приложение только включает/выключает их. Оставь пустым, чтобы всё работало локально, пока открыто приложение.")
                }
            }
            .navigationTitle("Скрипты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $setupAuto) {
            AutoSetupView(engine: engine).environmentObject(store)
        }
        .sheet(isPresented: $setupAI) {
            AISetupView(engine: engine).environmentObject(store)
        }
    }

    private var messageLineCount: Int {
        engine.config.autoMessages.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private func summary(guildId: String?, channels: [String], extra: String?) -> some View {
        let gname = store.guilds.first { $0.id == guildId }?.name ?? "сервер не выбран"
        return VStack(alignment: .leading, spacing: 2) {
            Text("Сервер: \(gname)")
            Text("Чатов: \(channels.count)")
            if let extra { Text(extra) }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.muted)
    }
}

// MARK: - Настройка автосообщений

private struct AutoSetupView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var engine: ScriptsEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ServerChannelSection(
                    guildId: Binding(get: { engine.config.autoGuildId }, set: { engine.config.autoGuildId = $0; engine.config.autoChannelIds = [] }),
                    channelIds: Binding(get: { engine.config.autoChannelIds }, set: { engine.config.autoChannelIds = $0 })
                )
                Section("Сообщения (каждая строка — отдельный вариант)") {
                    TextEditor(text: Binding(get: { engine.config.autoMessages }, set: { engine.config.autoMessages = $0 }))
                        .frame(minHeight: 160)
                        .font(.system(size: 15))
                }
            }
            .navigationTitle("Автосообщения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

// MARK: - Настройка ИИ-бота

private struct AISetupView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var engine: ScriptsEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ServerChannelSection(
                    guildId: Binding(get: { engine.config.aiGuildId }, set: { engine.config.aiGuildId = $0; engine.config.aiChannelIds = [] }),
                    channelIds: Binding(get: { engine.config.aiChannelIds }, set: { engine.config.aiChannelIds = $0 })
                )
            }
            .navigationTitle("ИИ-бот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

// MARK: - Общий выбор сервера и чатов

private struct ServerChannelSection: View {
    @EnvironmentObject var store: Store
    @Binding var guildId: String?
    @Binding var channelIds: [String]

    /// Каналы, куда можно писать: текстовые (0), войс-чаты (2), анонсы (5).
    private var channels: [Channel] {
        guard let gid = guildId else { return [] }
        return (store.guildChannels[gid] ?? [])
            .filter { !$0.isCategory && [0, 2, 5].contains($0.type) }
    }

    var body: some View {
        Section("Сервер") {
            Picker("Сервер", selection: $guildId) {
                Text("Не выбран").tag(String?.none)
                ForEach(store.guilds) { g in
                    Text(g.name).tag(String?.some(g.id))
                }
            }
        }
        .task(id: guildId) {
            if let gid = guildId, let g = store.guilds.first(where: { $0.id == gid }) {
                await store.loadGuildChannels(g)
            }
        }
        if guildId != nil {
            Section("Чаты") {
                if channels.isEmpty {
                    Text("Загрузка каналов…").foregroundStyle(Theme.muted)
                } else {
                    ForEach(channels) { ch in
                        Button {
                            if let i = channelIds.firstIndex(of: ch.id) { channelIds.remove(at: i) }
                            else { channelIds.append(ch.id) }
                        } label: {
                            HStack {
                                Image(systemName: ch.type == 2 ? "speaker.wave.2.fill" : "number")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.muted)
                                Text(ch.title).foregroundStyle(Theme.text)
                                Spacer()
                                if channelIds.contains(ch.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

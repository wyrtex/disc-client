import SwiftUI

// MARK: - Конфигурация скриптов (хранится в UserDefaults)

struct ScriptsConfig: Codable, Equatable {
    var autoEnabled = false
    var autoGuildId: String?
    var autoChannelIds: [String] = []
    var autoMessages = ""            // каждая строка — отдельный вариант сообщения

    var aiEnabled = false
    var aiGuildId: String?
    var aiChannelIds: [String] = []
}

// MARK: - Движок скриптов

/// Выполняет два фоновых скрипта, пока приложение открыто:
/// 1) Автосообщения — шлёт случайное сообщение из списка в выбранные чаты и сразу удаляет.
///    Пауза на час, если кто-то зашёл в войс или написал в наблюдаемый чат.
/// 2) ИИ-бот — анализирует чат и отвечает в его стиле, поддерживая диалог.
@MainActor
final class ScriptsEngine: ObservableObject {
    @Published var config = ScriptsConfig() { didSet { persist() } }
    weak var store: Store?

    private let key = "scriptsConfig"
    private var autoTask: Task<Void, Never>?
    private var autoPausedUntil = Date.distantPast
    private var aiCooldown: [String: Date] = [:]
    private var aiPending: [String: Task<Void, Never>] = [:]

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
    }

    func start() { restartAuto() }

    // MARK: Автосообщения

    private func restartAuto() {
        autoTask?.cancel()
        guard config.autoEnabled else { autoTask = nil; return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = Double.random(in: 60...180)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.tickAuto()
            }
        }
    }

    private func tickAuto() async {
        guard config.autoEnabled, Date() >= autoPausedUntil, let api = store?.api else { return }
        let lines = config.autoMessages
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, let cid = config.autoChannelIds.randomElement(), let text = lines.randomElement() else { return }
        do {
            let sent = try await api.sendMessage(channelId: cid, content: text, files: [], replyTo: nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await api.noContent("DELETE", "/channels/\(cid)/messages/\(sent.id)")
        } catch {
            // Тихо игнорируем (нет прав/слоумод/сеть) — попробуем в следующий тик.
        }
    }

    // MARK: Триггеры от Gateway

    /// Новое сообщение в канале (из Store.onMessage).
    func onMessage(_ msg: Message) {
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

        let prompt = """
        Ты — участник чата Discord и пишешь от первого лица, как обычный собеседник, а НЕ бот.
        Сначала проанализируй, как в этом чате общаются: язык, тон, длина сообщений, сленг, пунктуация, регистр букв. Ответь ТОЧНО в этом же стиле.

        Правила:
        - Отвечай, только если понял тему разговора и есть что сказать по существу. Если не уверен или тема непонятна — верни пустую строку.
        - Не спорь с людьми — они знают лучше. Поддерживай и соглашайся.
        - Никаких своих шуток, сарказма, подколов, лишних эмодзи.
        - Пиши коротко и естественно, как принято в этом чате, на языке чата.
        - Не представляйся, не упоминай что ты ИИ, не объясняй свои действия.

        Верни ТОЛЬКО текст ответа (одно сообщение) или пустую строку, если отвечать не стоит.

        Чат:
        \(transcript)
        """

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

    var body: some View {
        NavigationStack {
            List {
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

import SwiftUI

// MARK: - Модель активности

struct PresenceActivity: Codable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case game, listening, watching, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .game: return "Игра"
            case .listening: return "Слушает (Spotify)"
            case .watching: return "Смотрит (YouTube)"
            case .custom: return "Своё"
            }
        }
        var discordType: Int {
            switch self { case .game: return 0; case .listening: return 2; case .watching: return 3; case .custom: return 0 }
        }
    }

    var kind: Kind = .game
    var name: String = ""          // Stalkcraft / Spotify / YouTube …
    var details: String = ""       // строка 1 (трек / видео)
    var state: String = ""         // строка 2 (артист / канал)
    var largeImageURL: String = "" // обложка (ссылка)
    var largeText: String = ""
    var smallImageURL: String = ""
    var smallText: String = ""
    var showTimer: Bool = true     // «идёт N часов» (прошедшее от старта)
    var hasProgress: Bool = false  // прогресс-бар (нужна длительность)
    var durationSeconds: Int = 0

    // Spotify-специфика для настоящей зелёной карточки
    var spotifyTrackId: String = ""
    var spotifyImageId: String = ""

    // Для внешних картинок в Игре/Смотрит/Своё нужен id Discord-приложения
    var applicationId: String = ""

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind { case .listening: return "Spotify"; case .watching: return "YouTube"; default: return "Игра" }
    }
}

// MARK: - Менеджер presence

@MainActor
final class PresenceManager: ObservableObject {
    @Published var activity = PresenceActivity()
    @Published var enabled = false
    @Published var status = "online"       // online / idle / dnd / invisible
    @Published var working = false
    @Published var note = ""

    /// Отправка в гейтвей (op 3). Ставится из Store при подключении.
    var send: (([String: Any]) -> Bool)?
    /// Превратить ссылку на картинку во внешний ассет Discord: (appId, url) -> "mp:…".
    var resolveAsset: ((String, String) async -> String?)?
    var session: URLSession = .shared
    var userId = ""

    private let aKey = "presenceActivity"
    private let eKey = "presenceEnabled"
    private var startMs: Int?
    private var resolvedLarge = ""
    private var resolvedSmall = ""

    init() { load() }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: aKey),
           let a = try? JSONDecoder().decode(PresenceActivity.self, from: d) { activity = a }
        enabled = UserDefaults.standard.bool(forKey: eKey)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(activity) { UserDefaults.standard.set(d, forKey: aKey) }
        UserDefaults.standard.set(enabled, forKey: eKey)
    }

    /// При запуске/логине: если активность была включена — поднимаем её заново.
    func restoreIfNeeded() {
        guard enabled else { return }
        startMs = startMs ?? Int(Date().timeIntervalSince1970 * 1000)
        AudioHub.setKeepAlive(true)
        Task { await applyAsync(reset: false) }
    }

    /// Включить/обновить активность (резолвит картинки, потом отправляет op 3).
    func applyAsync(reset: Bool = true) async {
        working = true; note = ""
        defer { working = false }
        enabled = true
        if reset || startMs == nil { startMs = Int(Date().timeIntervalSince1970 * 1000) }

        // Внешние картинки (не Spotify) — через external-assets приложения.
        resolvedLarge = ""; resolvedSmall = ""
        if activity.kind != .listening, !activity.applicationId.isEmpty {
            if activity.largeImageURL.hasPrefix("http"), let r = await resolveAsset?(activity.applicationId, activity.largeImageURL) { resolvedLarge = r }
            if activity.smallImageURL.hasPrefix("http"), let r = await resolveAsset?(activity.applicationId, activity.smallImageURL) { resolvedSmall = r }
        }

        save()
        AudioHub.setKeepAlive(true)
        pushCurrent()
        note = "Активность включена"
    }

    /// Выключить активность.
    func disable() {
        enabled = false
        startMs = nil
        save()
        AudioHub.setKeepAlive(false)
        _ = send?(["op": 3, "d": ["since": 0, "activities": [], "status": status, "afk": false]])
        note = "Активность выключена"
    }

    /// Переотправка при реконнекте — startMs сохраняется, поэтому «идёт N часов» не сбрасывается.
    func resend() { if enabled { pushCurrent() } }

    func setStatus(_ s: String) {
        status = s
        if enabled { pushCurrent() } else {
            _ = send?(["op": 3, "d": ["since": 0, "activities": [], "status": status, "afk": false]])
        }
    }

    private func pushCurrent() {
        _ = send?(["op": 3, "d": ["since": 0, "activities": [buildActivity()], "status": status, "afk": false]])
    }

    private func buildActivity() -> [String: Any] {
        var a: [String: Any] = ["name": activity.displayName, "type": activity.kind.discordType]
        if !activity.details.isEmpty { a["details"] = activity.details }
        if !activity.state.isEmpty { a["state"] = activity.state }

        var ts: [String: Any] = [:]
        let start = startMs ?? Int(Date().timeIntervalSince1970 * 1000)
        if activity.showTimer || activity.hasProgress { ts["start"] = start }
        if activity.hasProgress, activity.durationSeconds > 0 { ts["end"] = start + activity.durationSeconds * 1000 }
        if !ts.isEmpty { a["timestamps"] = ts }

        var assets: [String: Any] = [:]
        if activity.kind == .listening, !activity.spotifyImageId.isEmpty {
            assets["large_image"] = "spotify:\(activity.spotifyImageId)"
        } else if !resolvedLarge.isEmpty {
            assets["large_image"] = resolvedLarge
        }
        if assets["large_image"] != nil, !activity.largeText.isEmpty { assets["large_text"] = activity.largeText }
        if !resolvedSmall.isEmpty {
            assets["small_image"] = resolvedSmall
            if !activity.smallText.isEmpty { assets["small_text"] = activity.smallText }
        }
        if !assets.isEmpty { a["assets"] = assets }

        if !activity.applicationId.isEmpty { a["application_id"] = activity.applicationId }

        if activity.kind == .listening {
            a["id"] = "spotify:1"
            a["flags"] = 48
            a["party"] = ["id": "spotify:\(userId)"]
            if !activity.spotifyTrackId.isEmpty { a["sync_id"] = activity.spotifyTrackId }
        }
        return a
    }

    // MARK: Автозаполнение по ссылке

    func fetchSpotify(_ link: String) async {
        working = true; note = ""
        defer { working = false }
        guard let id = extractID(link, marker: "/track/") else { note = "Это не ссылка на трек Spotify"; return }
        activity.kind = .listening
        activity.name = "Spotify"
        activity.spotifyTrackId = id
        do {
            let html = try await fetchHTML("https://open.spotify.com/track/\(id)")
            if let t = ogTag(html, "og:title") { activity.details = t }
            if let d = ogTag(html, "og:description") { activity.state = d.components(separatedBy: " · ").first ?? d }
            if let img = ogTag(html, "og:image"), let imgId = img.components(separatedBy: "/image/").last, !imgId.isEmpty {
                activity.spotifyImageId = imgId
                activity.largeText = activity.details
            }
            note = activity.details.isEmpty ? "Загрузил" : "Загрузил: \(activity.details)"
        } catch { note = "Не удалось загрузить страницу Spotify" }
    }

    func fetchYouTube(_ link: String) async {
        working = true; note = ""
        defer { working = false }
        guard let url = URL(string: "https://www.youtube.com/oembed?format=json&url=\(link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link)") else {
            note = "Некорректная ссылка"; return
        }
        do {
            let (data, _) = try await session.data(from: url)
            struct OE: Decodable { let title: String?; let author_name: String?; let thumbnail_url: String? }
            let oe = try JSONDecoder().decode(OE.self, from: data)
            activity.kind = .watching
            activity.name = "YouTube"
            if let t = oe.title { activity.details = t }
            if let a = oe.author_name { activity.state = a }
            if let th = oe.thumbnail_url { activity.largeImageURL = th; activity.largeText = oe.title ?? "" }
            note = "Загрузил: \(activity.details). Для обложки укажи id приложения."
        } catch { note = "Не удалось получить данные видео" }
    }

    // MARK: helpers

    private func extractID(_ link: String, marker: String) -> String? {
        guard let r = link.range(of: marker) else { return nil }
        let rest = link[r.upperBound...]
        let id = rest.prefix { $0.isLetter || $0.isNumber }
        return id.isEmpty ? nil : String(id)
    }

    private func fetchHTML(_ s: String) async throws -> String {
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return String(decoding: data, as: UTF8.self)
    }

    private func ogTag(_ html: String, _ property: String) -> String? {
        guard let r = html.range(of: "property=\"\(property)\"") else { return nil }
        let around = html[r.upperBound...].prefix(400)
        guard let c = around.range(of: "content=\"") else { return nil }
        let after = around[c.upperBound...]
        guard let end = after.range(of: "\"") else { return nil }
        let raw = String(after[..<end.lowerBound])
        return raw.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

// MARK: - Экран «Активность»

struct PresenceView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presence: PresenceManager

    @State private var link = ""
    @State private var minutes = 0
    @State private var seconds = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Показывать активность", isOn: Binding(
                        get: { presence.enabled },
                        set: { on in
                            if on { Task { await presence.applyAsync() } }
                            else { presence.disable() }
                        }
                    )).tint(Theme.blurple)

                    Picker("Статус", selection: Binding(get: { presence.status }, set: { presence.setStatus($0) })) {
                        Text("В сети").tag("online")
                        Text("Нет на месте").tag("idle")
                        Text("Не беспокоить").tag("dnd")
                        Text("Невидимка").tag("invisible")
                    }
                } footer: {
                    Text("Показывается, пока приложение держит связь. Чтобы работало и когда приложение свёрнуто, включается тихий фоновый режим (музыку он не трогает).")
                }

                Section("Тип") {
                    Picker("Тип активности", selection: $presence.activity.kind) {
                        ForEach(PresenceActivity.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }

                if presence.activity.kind == .listening {
                    Section("Автозаполнение из Spotify") {
                        TextField("Ссылка на трек Spotify", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Загрузить трек") { Task { await presence.fetchSpotify(link) } }
                            .disabled(link.isEmpty || presence.working)
                    }
                }
                if presence.activity.kind == .watching {
                    Section("Автозаполнение из YouTube") {
                        TextField("Ссылка на видео YouTube", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Загрузить видео") { Task { await presence.fetchYouTube(link) } }
                            .disabled(link.isEmpty || presence.working)
                    }
                }

                Section("Текст") {
                    TextField(namePlaceholder, text: $presence.activity.name)
                    TextField("Строка 1 (details)", text: $presence.activity.details)
                    TextField("Строка 2 (state)", text: $presence.activity.state)
                }

                Section {
                    Toggle("Таймер «идёт N часов»", isOn: $presence.activity.showTimer).tint(Theme.blurple)
                    Toggle("Прогресс-бар", isOn: $presence.activity.hasProgress).tint(Theme.blurple)
                    if presence.activity.hasProgress {
                        HStack {
                            Text("Длительность")
                            Spacer()
                            Picker("мин", selection: $minutes) { ForEach(0..<60) { Text("\($0) м").tag($0) } }
                                .pickerStyle(.wheel).frame(width: 90, height: 90).clipped()
                            Picker("сек", selection: $seconds) { ForEach(0..<60) { Text("\($0) с").tag($0) } }
                                .pickerStyle(.wheel).frame(width: 90, height: 90).clipped()
                        }
                    }
                } header: {
                    Text("Время")
                } footer: {
                    Text("Таймер показывает, сколько времени идёт активность. Прогресс-бар нужен для трека/видео (ползёт от 0 до длительности).")
                }

                Section {
                    TextField("Ссылка на большую картинку", text: $presence.activity.largeImageURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Подпись большой картинки", text: $presence.activity.largeText)
                    TextField("Ссылка на маленькую картинку", text: $presence.activity.smallImageURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Подпись маленькой картинки", text: $presence.activity.smallText)
                    if presence.activity.kind != .listening {
                        TextField("ID Discord-приложения (для картинок)", text: $presence.activity.applicationId)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("Картинки")
                } footer: {
                    if presence.activity.kind == .listening {
                        Text("Для Spotify обложка берётся из ссылки на трек автоматически.")
                    } else {
                        Text("Произвольные картинки Discord показывает только через id приложения. Создай любое приложение на discord.com/developers → скопируй Application ID сюда. Без него картинки пропускаются.")
                    }
                }

                if !presence.note.isEmpty {
                    Section { Text(presence.note).foregroundStyle(Theme.muted).font(.footnote) }
                }

                Section {
                    Button {
                        syncDuration()
                        Task { await presence.applyAsync() }
                    } label: {
                        HStack {
                            if presence.working { ProgressView() }
                            Text("Применить").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(presence.working)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.chat)
            .navigationTitle("Активность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .onAppear {
                minutes = presence.activity.durationSeconds / 60
                seconds = presence.activity.durationSeconds % 60
            }
            .onChange(of: minutes) { _, _ in syncDuration() }
            .onChange(of: seconds) { _, _ in syncDuration() }
        }
        .presentationBackground(Theme.chat)
    }

    private func syncDuration() {
        presence.activity.durationSeconds = minutes * 60 + seconds
    }

    private var namePlaceholder: String {
        switch presence.activity.kind {
        case .game: return "Название игры"
        case .listening: return "Spotify"
        case .watching: return "YouTube"
        case .custom: return "Название"
        }
    }
}


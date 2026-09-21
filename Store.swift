import Foundation
import SwiftUI
import SwiftOGG

enum GuildVoiceSummary {
    case none, voice, video, stream
}

struct VoiceMemberState: Equatable {
    var userId: String
    var channelId: String
    var mute = false
    var deaf = false
    var video = false
    var stream = false
}

@MainActor
final class Store: ObservableObject {
    @Published var me: User?
    @Published var guilds: [Guild] = []
    @Published var dms: [Channel] = []
    @Published var guildChannels: [String: [Channel]] = [:]
    @Published var viewable: [String: Set<String>] = [:]
    @Published var guildDetails: [String: GuildDetail] = [:]
    @Published var guildRoles: [String: [GuildRole]] = [:]
    @Published var guildEmojis: [String: [GuildEmoji]] = [:]
    @Published var messages: [String: [Message]] = [:]
    @Published var forumThreads: [String: [Channel]] = [:]
    @Published var forumPreviews: [String: Message] = [:]
    @Published var forumHasMore: [String: Bool] = [:]
    @Published var path: [Channel] = []
    @Published var voiceRoster: [String: [String: VoiceMemberState]] = [:]
    @Published var voiceUsers: [String: User] = [:]
    @Published var memberRoles: [String: Set<String>] = [:]
    @Published var loadingOlder: Set<String> = []
    @Published var reachedTop: Set<String> = []
    @Published var detachedChannels: Set<String> = []
    var selectedGuildId: String?
    private var userFailedAt: [String: Date] = [:]
    private var userInFlight: [String: Task<User?, Never>] = [:]
    private let userLimiter = AsyncLimiter(limit: 2)
    private var loginStatus: Int?
    private var lastLoginError: String?
    @Published var error: String?
    @Published var isLoading = false
    @Published var proxy: ProxySettings {
        didSet {
            if let data = try? JSONEncoder().encode(proxy) {
                UserDefaults.standard.set(data, forKey: "proxy")
            }
        }
    }

    var lastChannel: Channel?
    let voice = VoiceSpike()
    private(set) var api: API?
    private var gateway: Gateway?

    init() {
        if let data = UserDefaults.standard.data(forKey: "proxy"),
           let p = try? JSONDecoder().decode(ProxySettings.self, from: data) {
            proxy = p
        } else {
            proxy = ProxySettings()
        }
        if let saved = Keychain.load() {
            Task { await autoLogin(saved) }
        }
    }

    /// Вход при запуске: если сети ещё нет (например, VPN поднимается), тихо повторяем несколько раз.
    private func autoLogin(_ token: String) async {
        for attempt in 0..<8 {
            await login(token: token, silent: true)
            if me != nil { return }
            if let code = loginStatus, code == 401 || code == 403 { break }
            try? await Task.sleep(nanoseconds: UInt64(2 + attempt) * 1_000_000_000)
        }
        if me == nil { error = lastLoginError }
    }

    // MARK: - Вход / выход

    func login(token: String, silent: Bool = false) async {
        let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\""))
        guard !clean.isEmpty else { return }
        isLoading = true
        if !silent { error = nil }
        defer { isLoading = false }

        let api = API(token: clean, proxy: proxy)
        do {
            let me: User = try await api.get("/users/@me")
            let g: [Guild] = try await api.get("/users/@me/guilds")
            let d: [Channel] = try await api.get("/users/@me/channels")
            self.api = api
            self.me = me
            self.guilds = g
            self.dms = d.sorted { (UInt64($0.last_message_id ?? "0") ?? 0) > (UInt64($1.last_message_id ?? "0") ?? 0) }
            ImageLoader.shared.session = api.session
            voice.session = api.session
            voice.userId = me.id
            voice.resolveUser = { [weak self] id in await self?.fetchUser(id) }
            voice.cachedUser = { [weak self] id in
                guard let self else { return nil }
                if let me = self.me, me.id == id { return me }
                return self.voiceUsers[id]
            }
            Keychain.save(clean)
            startGateway(token: clean, session: api.session)
        } catch {
            lastLoginError = error.localizedDescription
            if case APIError.http(let code, _) = error { loginStatus = code } else { loginStatus = nil }
            if !silent { self.error = error.localizedDescription }
        }
    }

    func logout() {
        voice.leave(silent: true)
        gateway?.stop()
        gateway = nil
        api = nil
        me = nil
        guilds = []
        dms = []
        guildChannels = [:]
        viewable = [:]
        guildDetails = [:]
        guildRoles = [:]
        guildEmojis = [:]
        messages = [:]
        forumThreads = [:]
        forumPreviews = [:]
        voiceRoster = [:]
        voiceUsers = [:]
        memberRoles = [:]
        reachedTop = []
        detachedChannels = []
        path = []
        lastChannel = nil
        Keychain.delete()
    }

    /// Приложение вернулось на экран: проверяем, жив ли Gateway.
    func appBecameActive() {
        gateway?.ensureConnected()
    }

    private func startGateway(token: String, session: URLSession) {
        gateway?.stop()
        let gw = Gateway(token: token, session: session)
        gw.onMessage = { [weak self] msg in
            Task { @MainActor in
                guard let self, self.messages[msg.channel_id] != nil else { return }
                self.merge([msg], into: msg.channel_id)
            }
        }
        gw.onEvent = { [weak self] t, d in
            Task { @MainActor in
                self?.voice.handle(t, d)
                if t == "VOICE_STATE_UPDATE" { self?.applyVoiceStateUpdate(d) }
            }
        }
        gw.onGuildVoiceStates = { [weak self] list in
            Task { @MainActor in self?.setGuildVoiceStates(list) }
        }
        gw.onDispatchName = { [weak self] t in
            Task { @MainActor in self?.voice.noteEvent(t) }
        }
        gw.onLog = { [weak self] s in
            Task { @MainActor in self?.voice.addGateway(s) }
        }
        gw.onReady = { [weak self] in
            Task { @MainActor in self?.voice.gatewayReady() }
        }
        voice.sendGateway = { [weak gw] obj in gw?.sendRaw(obj) ?? false }
        voice.ensureGateway = { [weak gw] in gw?.ensureConnected() }
        gw.start()
        gateway = gw
    }

    // MARK: - Серверы и каналы

    func guildID(of ch: Channel) -> String? {
        if let g = ch.guild_id { return g }
        for (gid, list) in guildChannels {
            if list.contains(where: { $0.id == ch.id || $0.id == ch.parent_id }) { return gid }
        }
        return nil
    }

    func isLocked(_ ch: Channel, guildId: String) -> Bool {
        guard let allowed = viewable[guildId] else { return false }
        return !allowed.contains(ch.id)
    }

    /// Загружает каналы сервера и вычисляет, какие из них тебе недоступны.
    func loadGuildChannels(_ guild: Guild) async {
        guard let api, let me else { return }
        if guildChannels[guild.id] != nil { return }
        do {
            let all: [Channel] = try await api.get("/guilds/\(guild.id)/channels")
            if let member: GuildMember = try? await api.get("/users/@me/guilds/\(guild.id)/member") {
                memberRoles[guild.id] = Set(member.roles)
                if let ids = Store.viewableIDs(all, guild: guild, roles: Set(member.roles), meId: me.id) {
                    viewable[guild.id] = ids
                }
            }
            guildChannels[guild.id] = all
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// nil означает «все каналы доступны» (владелец, админ или права неизвестны).
    private static func viewableIDs(_ all: [Channel], guild: Guild, roles: Set<String>, meId: String) -> Set<String>? {
        guard let permStr = guild.permissions, let base = UInt64(permStr) else { return nil }
        let admin: UInt64 = 1 << 3
        let view: UInt64 = 1 << 10
        if guild.owner == true || (base & admin) != 0 { return nil }

        func canView(_ ch: Channel) -> Bool {
            var perms = base
            let ows = ch.permission_overwrites ?? []
            if let e = ows.first(where: { !$0.isMember && $0.id == guild.id }) {
                perms &= ~e.deny
                perms |= e.allow
            }
            var allow: UInt64 = 0
            var deny: UInt64 = 0
            for o in ows where !o.isMember && roles.contains(o.id) {
                allow |= o.allow
                deny |= o.deny
            }
            perms &= ~deny
            perms |= allow
            if let m = ows.first(where: { $0.isMember && $0.id == meId }) {
                perms &= ~m.deny
                perms |= m.allow
            }
            return (perms & view) != 0
        }

        return Set(all.filter { !$0.isCategory && canView($0) }.map { $0.id })
    }

    func loadGuildDetail(_ guildId: String) async -> GuildDetail? {
        if let d = guildDetails[guildId] { return d }
        guard let api else { return nil }
        let d: GuildDetail? = try? await api.get("/guilds/\(guildId)?with_counts=true")
        if let d { guildDetails[guildId] = d }
        return d
    }

    func loadRoles(_ guildId: String) async {
        guard let api, guildRoles[guildId] == nil else { return }
        if let roles: [GuildRole] = try? await api.get("/guilds/\(guildId)/roles") {
            guildRoles[guildId] = roles
        }
    }

    func loadEmojis(_ guildId: String) async {
        guard let api, guildEmojis[guildId] == nil else { return }
        if let list: [GuildEmoji] = try? await api.get("/guilds/\(guildId)/emojis") {
            guildEmojis[guildId] = list
        }
    }

    // MARK: - Профили и личные сообщения

    func loadProfile(_ user: User, guildId: String?) async -> ProfileResponse? {
        guard let api else { return nil }
        var p = "/users/\(user.id)/profile?with_mutual_guilds=true"
        if let guildId { p += "&guild_id=\(guildId)" }
        let r: ProfileResponse? = try? await api.get(p)
        return r
    }

    // MARK: - Кто сидит в голосовых каналах

    func members(in channelId: String, guildId: String) -> [VoiceMemberState] {
        (voiceRoster[guildId] ?? [:]).values
            .filter { $0.channelId == channelId }
            .sorted { $0.userId < $1.userId }
    }

    func setGuildVoiceStates(_ list: [(String, [[String: Any]])]) {
        for (gid, states) in list {
            var map: [String: VoiceMemberState] = [:]
            for s in states {
                if let m = parseVoiceState(s) { map[m.userId] = m }
                cacheVoiceUser(from: s)
            }
            voiceRoster[gid] = map
        }
        resolveMissingVoiceUsers()
    }

    func applyVoiceStateUpdate(_ d: [String: Any]) {
        guard let gid = d["guild_id"] as? String, let uid = d["user_id"] as? String else { return }
        if let m = parseVoiceState(d) {
            var map = voiceRoster[gid] ?? [:]
            map[uid] = m
            voiceRoster[gid] = map
        } else if voiceRoster[gid]?[uid] != nil {
            voiceRoster[gid]?[uid] = nil
        }
        cacheVoiceUser(from: d)
        resolveMissingVoiceUsers()
    }

    private func parseVoiceState(_ d: [String: Any]) -> VoiceMemberState? {
        guard let uid = d["user_id"] as? String, let cid = d["channel_id"] as? String else { return nil }
        let mute = (d["self_mute"] as? Bool ?? false) || (d["mute"] as? Bool ?? false)
        let deaf = (d["self_deaf"] as? Bool ?? false) || (d["deaf"] as? Bool ?? false)
        return VoiceMemberState(
            userId: uid,
            channelId: cid,
            mute: mute,
            deaf: deaf,
            video: d["self_video"] as? Bool ?? false,
            stream: d["self_stream"] as? Bool ?? false
        )
    }

    private func cacheVoiceUser(from d: [String: Any]) {
        guard let member = d["member"] as? [String: Any],
              let userObj = member["user"] as? [String: Any],
              let uid = userObj["id"] as? String,
              voiceUsers[uid] == nil,
              let data = try? JSONSerialization.data(withJSONObject: userObj),
              let user = try? JSONDecoder().decode(User.self, from: data) else { return }
        voiceUsers[uid] = user
    }

    /// Профили дотягиваем только для открытого сервера, чтобы не забивать сеть (и голосовой канал).
    private func resolveMissingVoiceUsers() {
        if let g = selectedGuildId { resolveVoiceUsers(guildId: g) }
    }

    /// Профиль пользователя по id (для подписей участников голосового канала).
    func fetchUser(_ id: String) async -> User? {
        if let me, me.id == id { return me }
        if let u = voiceUsers[id] { return u }
        guard let api else { return nil }
        if let t = userFailedAt[id], Date().timeIntervalSince(t) < 90 { return nil }
        if let existing = userInFlight[id] { return await existing.value }

        let limiter = userLimiter
        let task = Task<User?, Never> {
            await limiter.acquire()
            var found: User?
            if let u: User = try? await api.get("/users/\(id)") {
                found = u
            } else if let r: ProfileResponse = try? await api.get("/users/\(id)/profile"), let u = r.user {
                found = u
            }
            await limiter.release()
            return found
        }
        userInFlight[id] = task
        let result = await task.value
        userInFlight[id] = nil
        if let result {
            voiceUsers[id] = result
        } else {
            userFailedAt[id] = Date()
        }
        return result
    }

    /// Имя канала по id (для упоминаний #канал; показываем и недоступные каналы).
    func channelName(_ id: String) -> String? {
        for list in guildChannels.values {
            if let c = list.first(where: { $0.id == id }) { return c.name }
        }
        if let dm = dms.first(where: { $0.id == id }) { return dm.title }
        return nil
    }

    /// Поиск участников сервера для подсказок при вводе @.
    func searchMembers(guildId: String, query: String) async -> [User] {
        guard let api, !query.isEmpty else { return [] }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let list: [MemberSearchItem] = try? await api.get("/guilds/\(guildId)/members/search?query=\(q)&limit=8") {
            return list.map { $0.user }
        }
        return []
    }

    /// Значок сервера в левой колонке: кто-то стримит, у кого-то камера или просто есть люди в голосе.
    func guildVoiceSummary(_ guildId: String) -> GuildVoiceSummary {
        guard let map = voiceRoster[guildId], !map.isEmpty else { return .none }
        if map.values.contains(where: { $0.stream }) { return .stream }
        if map.values.contains(where: { $0.video }) { return .video }
        return .voice
    }

    func resolveVoiceUsers(guildId: String) {
        guard let map = voiceRoster[guildId] else { return }
        for uid in map.keys where voiceUsers[uid] == nil {
            Task { [weak self] in _ = await self?.fetchUser(uid) }
        }
    }

    func openDM(with user: User) async {
        guard let api else { return }
        if let existing = dms.first(where: { $0.type == 1 && $0.recipients?.first?.id == user.id }) {
            path.append(existing)
            return
        }
        do {
            let ch: Channel = try await api.post("/users/@me/channels", body: ["recipient_id": user.id])
            if !dms.contains(where: { $0.id == ch.id }) { dms.insert(ch, at: 0) }
            path.append(ch)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Сообщения

    /// Подгрузка более старых сообщений. Возвращает id бывшего первого сообщения (чтобы удержать позицию прокрутки).
    func loadOlder(_ channelId: String) async -> String? {
        guard let api,
              !loadingOlder.contains(channelId),
              !reachedTop.contains(channelId),
              let first = messages[channelId]?.first else { return nil }
        loadingOlder.insert(channelId)
        defer { loadingOlder.remove(channelId) }
        do {
            let list: [Message] = try await api.get("/channels/\(channelId)/messages?limit=50&before=\(first.id)")
            if list.count < 50 { reachedTop.insert(channelId) }
            if list.isEmpty { return nil }
            merge(list, into: channelId)
            return first.id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Прыжок к старому сообщению: заменяем окно сообщений на окно вокруг него.
    func loadAround(_ channelId: String, messageId: String) async -> Bool {
        guard let api else { return false }
        do {
            let list: [Message] = try await api.get("/channels/\(channelId)/messages?limit=50&around=\(messageId)")
            guard !list.isEmpty else { return false }
            messages[channelId] = list.sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
            detachedChannels.insert(channelId)
            reachedTop.remove(channelId)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func returnToLatest(_ channelId: String) async {
        detachedChannels.remove(channelId)
        reachedTop.remove(channelId)
        messages[channelId] = []
        await loadMessages(channelId)
    }

    func loadMessages(_ channelId: String, silent: Bool = false) async {
        guard let api, !detachedChannels.contains(channelId) else { return }
        do {
            let list: [Message] = try await api.get("/channels/\(channelId)/messages?limit=50")
            merge(list, into: channelId)
        } catch {
            if !silent { self.error = error.localizedDescription }
        }
    }

    func send(_ text: String, files: [UploadFile], to channelId: String, replyTo: String? = nil) async -> Bool {
        guard let api else { return false }
        do {
            let m = try await api.sendMessage(channelId: channelId, content: text, files: files, replyTo: replyTo)
            merge([m], into: channelId)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func toggleReaction(_ emoji: EmojiRef, on m: Message) async {
        guard let api else { return }
        let has = m.reactions.first(where: { $0.emoji == emoji })?.me ?? false
        do {
            try await api.noContent(has ? "DELETE" : "PUT",
                                    "/channels/\(m.channel_id)/messages/\(m.id)/reactions/\(emoji.apiPath)/@me")
            await loadMessages(m.channel_id, silent: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Голосовое сообщение: m4a -> OGG/Opus -> загрузка -> сообщение. Без каких-либо фильтров.
    func sendVoice(_ rec: RecordedVoice, to channelId: String, replyTo: String? = nil) async -> Bool {
        guard let api else { return false }
        let src = rec.url
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).ogg")
        defer {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.removeItem(at: src)
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try OGGConverter.convertM4aFileToOpusOGG(src: src, dest: dest)
            }.value
            let data = try Data(contentsOf: dest)
            let m = try await api.sendVoiceMessage(
                channelId: channelId,
                ogg: data,
                duration: rec.duration,
                waveform: rec.waveformBase64,
                replyTo: replyTo
            )
            merge([m], into: channelId)
            return true
        } catch {
            self.error = "Голосовое сообщение: " + error.localizedDescription
            return false
        }
    }

    func forward(_ m: Message, from source: Channel, to target: Channel) async -> Bool {
        guard let api else { return false }
        var ref: [String: Any] = ["type": 1, "message_id": m.id, "channel_id": m.channel_id]
        if let gid = guildID(of: source) { ref["guild_id"] = gid }
        let body: [String: Any] = [
            "message_reference": ref,
            "nonce": String(Int(Date().timeIntervalSince1970 * 1000))
        ]
        do {
            let sent: Message = try await api.post("/channels/\(target.id)/messages", body: body)
            if messages[target.id] != nil { merge([sent], into: target.id) }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func merge(_ new: [Message], into channelId: String) {
        var dict: [String: Message] = [:]
        for m in messages[channelId] ?? [] { dict[m.id] = m }
        for m in new { dict[m.id] = m }
        messages[channelId] = dict.values.sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
    }

    // MARK: - Форумы

    func loadForum(_ forum: Channel, more: Bool = false) async {
        guard let api else { return }
        let offset = more ? (forumThreads[forum.id]?.count ?? 0) : 0
        let q = "?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&offset=\(offset)"
        do {
            let r: ThreadSearchResult = try await api.get("/channels/\(forum.id)/threads/search" + q)
            var list = more ? (forumThreads[forum.id] ?? []) : []
            let known = Set(list.map { $0.id })
            list.append(contentsOf: r.threads.filter { !known.contains($0.id) })
            forumThreads[forum.id] = list
            for m in r.first_messages { forumPreviews[m.channel_id] = m }
            forumHasMore[forum.id] = r.has_more
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createPost(in forum: Channel, title: String, text: String) async -> Channel? {
        guard let api else { return nil }
        let body: [String: Any] = [
            "name": title,
            "auto_archive_duration": 4320,
            "message": ["content": text]
        ]
        do {
            let ch: Channel = try await api.post("/channels/\(forum.id)/threads", body: body)
            forumThreads[forum.id] = [ch] + (forumThreads[forum.id] ?? [])
            return ch
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

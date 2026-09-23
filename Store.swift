import Foundation
import SwiftUI
import SwiftOGG

/// Кэш последних ответов Discord на диске: приложение открывается сразу, а обновляется уже в фоне.
enum DiskCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("disc", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ data: Data, _ name: String) {
        try? data.write(to: dir.appendingPathComponent(name + ".json"))
    }

    static func load(_ name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name + ".json"))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}

enum GuildVoiceSummary {
    case none, voice, video, stream
}

struct MemberInfo {
    var nick: String?
    var roles: [String]
}

struct VoiceMemberState: Equatable {
    var userId: String
    var channelId: String
    var mute = false
    var deaf = false
    var video = false
    var stream = false
    var suppress = false
    var requestToSpeak = false
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
    @Published var isRestoring = false
    var gatewaySessionId: String?
    @Published var dmPreviews: [String: Message] = [:]
    @Published var guildMembers: [String: [String: MemberInfo]] = [:]
    private var memberTimeout: [String: Date] = [:]
    private var requestedMembers: [String: Set<String>] = [:]
    private var previewInFlight = Set<String>()
    private let previewLimiter = AsyncLimiter(limit: 2)
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

    // MARK: - Непрочитанное (белый кружок) и упоминания (красный кружок)

    /// Канал, открытый прямо сейчас в ChatView — для него новые сообщения не считаются непрочитанными.
    var openChannelId: String?
    @Published var unreadChannels: Set<String> = []
    @Published var mentionChannels: Set<String> = []
    private var lastRead: [String: String] = UserDefaults.standard.dictionary(forKey: "lastRead") as? [String: String] ?? [:]
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
        VPNManager.shared.onProxyChange = { [weak self] p in
            Task { @MainActor in self?.proxy = p }
        }
        if let saved = Keychain.load() {
            isRestoring = !restoreFromCache()
            Task { await autoLogin(saved) }
            if VPNManager.shared.autoConnect {
                Task {
                    await VPNManager.shared.loadSubscription()
                    await VPNManager.shared.connectBest()
                }
            }
        }
    }

    /// Показываем сохранённые данные сразу, пока идёт вход.
    private func restoreFromCache() -> Bool {
        guard let m = DiskCache.load("me"),
              let g = DiskCache.load("guilds"),
              let d = DiskCache.load("dms"),
              let me = try? JSONDecoder().decode(User.self, from: m),
              let guilds = try? JSONDecoder().decode([Guild].self, from: g),
              let dms = try? JSONDecoder().decode([Channel].self, from: d) else { return false }
        self.me = me
        self.guilds = Store.applySavedOrder(guilds)
        self.dms = dms.sorted { (UInt64($0.last_message_id ?? "0") ?? 0) > (UInt64($1.last_message_id ?? "0") ?? 0) }
        return true
    }

    /// Вход при запуске: если сети ещё нет (например, VPN поднимается), тихо повторяем несколько раз.
    private func autoLogin(_ token: String) async {
        for attempt in 0..<8 {
            await login(token: token, silent: true)
            if me != nil { return }
            if let code = loginStatus, code == 401 || code == 403 {
                // Токен больше не действует: возвращаемся на экран входа.
                logout()
                error = lastLoginError
                isRestoring = false
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(2 + attempt) * 1_000_000_000)
        }
        isRestoring = false
        if api == nil, me == nil { error = lastLoginError }
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
            let meData = try await api.raw("/users/@me")
            let gData = try await api.raw("/users/@me/guilds")
            let dData = try await api.raw("/users/@me/channels")
            let me = try JSONDecoder().decode(User.self, from: meData)
            let g = try JSONDecoder().decode([Guild].self, from: gData)
            let d = try JSONDecoder().decode([Channel].self, from: dData)
            DiskCache.save(meData, "me")
            DiskCache.save(gData, "guilds")
            DiskCache.save(dData, "dms")
            self.api = api
            self.me = me
            self.guilds = Store.applySavedOrder(g)
            self.dms = d.sorted { (UInt64($0.last_message_id ?? "0") ?? 0) > (UInt64($1.last_message_id ?? "0") ?? 0) }
            ImageLoader.shared.session = api.session
            voice.session = api.session
            voice.userId = me.id
            voice.resolveUser = { [weak self] id in await self?.fetchUser(id) }
            voice.patchVoiceState = { [weak self] gid, body in
                guard let self, let api = self.api else { return false }
                do {
                    try await api.noContent("PATCH", "/guilds/\(gid)/voice-states/@me", body: body)
                    return true
                } catch {
                    self.error = error.localizedDescription
                    return false
                }
            }
            voice.fetchStageTopic = { [weak self] cid in
                struct StageInstance: Decodable { let topic: String? }
                guard let api = self?.api else { return nil }
                let s: StageInstance? = try? await api.get("/stage-instances/\(cid)")
                return s?.topic
            }
            voice.cachedUser = { [weak self] id in
                guard let self else { return nil }
                if let me = self.me, me.id == id { return me }
                return self.voiceUsers[id]
            }
            Keychain.save(clean)
            isRestoring = false
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
        DiskCache.clear()
        gatewaySessionId = nil
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
                guard let self else { return }
                self.noteDMMessage(msg)
                self.noteIncomingForUnread(msg)
                guard self.messages[msg.channel_id] != nil else { return }
                self.merge([msg], into: msg.channel_id)
            }
        }
        gw.onEvent = { [weak self] t, d in
            Task { @MainActor in
                guard let self else { return }
                switch t {
                case "MESSAGE_UPDATE": self.applyMessageUpdate(d)
                case "MESSAGE_DELETE": self.applyMessageDelete(d)
                case "GUILD_MEMBERS_CHUNK": self.applyMembersChunk(d)
                default:
                    self.voice.handle(t, d)
                    if t == "VOICE_STATE_UPDATE" { self.applyVoiceStateUpdate(d) }
                }
            }
        }
        gw.onSessionId = { [weak self] sid in
            Task { @MainActor in self?.gatewaySessionId = sid }
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
                if let until = member.communication_disabled_until, let date = Store.parseISO(until) {
                    memberTimeout[guild.id] = date
                }
                if let ids = Store.viewableIDs(all, guild: guild, roles: Set(member.roles), meId: me.id) {
                    viewable[guild.id] = ids
                }
            }
            guildChannels[guild.id] = all
            for ch in all {
                guard let last = ch.last_message_id else { continue }
                if let known = lastRead[ch.id], known != last {
                    unreadChannels.insert(ch.id)
                }
            }
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
        var p = "/users/\(user.id)/profile?with_mutual_guilds=true&with_mutual_friends_count=true"
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
            stream: d["self_stream"] as? Bool ?? false,
            suppress: d["suppress"] as? Bool ?? false,
            requestToSpeak: (d["request_to_speak_timestamp"] as? String) != nil
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
            pruneDeleted(channelId, fetched: list)
        } catch {
            if !silent { self.error = error.localizedDescription }
        }
    }

    /// Сообщения, которые попадают в свежий диапазон, но сервер их больше не отдаёт, удалены.
    private func pruneDeleted(_ channelId: String, fetched: [Message]) {
        guard fetched.count >= 2,
              let minId = fetched.compactMap({ UInt64($0.id) }).min(),
              let local = messages[channelId] else { return }
        let ids = Set(fetched.map { $0.id })
        let kept = local.filter { m in
            guard let v = UInt64(m.id) else { return true }
            return v < minId || ids.contains(m.id)
        }
        if kept.count != local.count { messages[channelId] = kept }
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

    // MARK: - Кнопки и меню ботов

    private func guildId(forChannelId cid: String) -> String? {
        for (gid, list) in guildChannels where list.contains(where: { $0.id == cid }) {
            return gid
        }
        return nil
    }

    private func sendInteraction(_ m: Message, data: [String: Any]) async {
        guard let api else { return }
        guard let session = gatewaySessionId else {
            error = "Сессия Discord ещё не готова. Подожди секунду и повтори."
            return
        }
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let nonce = String((ms &- 1_420_070_400_000) << 22)
        var body: [String: Any] = [
            "type": 3,
            "nonce": nonce,
            "channel_id": m.channel_id,
            "message_flags": m.flags,
            "message_id": m.id,
            "application_id": m.application_id ?? m.author.id,
            "session_id": session,
            "data": data
        ]
        if let gid = guildId(forChannelId: m.channel_id) { body["guild_id"] = gid }
        do {
            try await api.noContent("POST", "/interactions", body: body)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await loadMessages(m.channel_id, silent: true)
        } catch {
            self.error = "Не удалось нажать кнопку: " + error.localizedDescription
        }
    }

    func pressButton(_ m: Message, customId: String) async {
        await sendInteraction(m, data: ["component_type": 2, "custom_id": customId])
    }

    func selectOption(_ m: Message, customId: String, values: [String]) async {
        await sendInteraction(m, data: ["component_type": 3, "custom_id": customId, "type": 3, "values": values])
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

    /// Похоже ли сообщение на упоминание текущего пользователя (себя, @everyone/@here или своей роли).
    func isMentioned(_ m: Message, guildId: String?) -> Bool {
        guard let me, m.author.id != me.id else { return false }
        if m.mention_everyone { return true }
        if m.mentions.contains(where: { $0.id == me.id }) { return true }
        if let gid = guildId, let roles = memberRoles[gid], !roles.isDisjoint(with: m.mention_roles) {
            return true
        }
        return false
    }

    /// Новое сообщение из Gateway: если канал сейчас не открыт, отмечаем непрочитанным (и упоминанием, если задели тебя).
    private func noteIncomingForUnread(_ msg: Message) {
        guard let me, msg.author.id != me.id else { return }
        if msg.channel_id == openChannelId {
            markRead(msg.channel_id, upTo: msg.id)
            return
        }
        unreadChannels.insert(msg.channel_id)
        let gid = guildID(of: msg.channel_id)
        if isMentioned(msg, guildId: gid) {
            mentionChannels.insert(msg.channel_id)
        }
    }

    private func guildID(of channelId: String) -> String? {
        for (gid, list) in guildChannels where list.contains(where: { $0.id == channelId }) {
            return gid
        }
        return nil
    }

    /// Отметить канал прочитанным: убираем кружки, запоминаем последнее увиденное сообщение.
    func markRead(_ channelId: String, upTo messageId: String? = nil) {
        unreadChannels.remove(channelId)
        mentionChannels.remove(channelId)
        let id = messageId ?? messages[channelId]?.last?.id
        guard let id else { return }
        lastRead[channelId] = id
        UserDefaults.standard.set(lastRead, forKey: "lastRead")
    }

    /// Красный кружок на иконке сервера: хотя бы один канал внутри с непрочитанным упоминанием.
    func guildHasMentions(_ guildId: String) -> Bool {
        guard let list = guildChannels[guildId] else { return false }
        return list.contains { mentionChannels.contains($0.id) }
    }

    // MARK: - Правка и удаление своих сообщений

    func edit(_ m: Message, content: String) async -> Bool {
        guard let api else { return false }
        do {
            let updated: Message = try await api.send("PATCH", "/channels/\(m.channel_id)/messages/\(m.id)", body: ["content": content])
            merge([updated], into: m.channel_id)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(_ m: Message) async -> Bool {
        guard let api else { return false }
        do {
            try await api.noContent("DELETE", "/channels/\(m.channel_id)/messages/\(m.id)")
            messages[m.channel_id]?.removeAll { $0.id == m.id }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    fileprivate func applyMessageUpdate(_ d: [String: Any]) {
        guard let cid = d["channel_id"] as? String, messages[cid] != nil,
              let data = try? JSONSerialization.data(withJSONObject: d),
              let msg = try? JSONDecoder().decode(Message.self, from: data) else { return }
        merge([msg], into: cid)
    }

    fileprivate func applyMessageDelete(_ d: [String: Any]) {
        guard let cid = d["channel_id"] as? String, let id = d["id"] as? String else { return }
        messages[cid]?.removeAll { $0.id == id }
    }

    // MARK: - Права на отправку сообщений

    static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f1.date(from: s) ?? f2.date(from: s)
    }

    private static func permissions(for ch: Channel, guild: Guild, roles: Set<String>, meId: String) -> UInt64? {
        guard let permStr = guild.permissions, let base = UInt64(permStr) else { return nil }
        let admin: UInt64 = 1 << 3
        if guild.owner == true || (base & admin) != 0 { return UInt64.max }

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
        return perms
    }

    /// Можно ли писать в канал. Если данных не хватает, считаем, что можно.
    func canSend(in ch: Channel) -> Bool {
        guard let gid = guildID(of: ch),
              let guild = guilds.first(where: { $0.id == gid }),
              let me,
              let roles = memberRoles[gid] else { return true }
        if let until = memberTimeout[gid], until > Date() { return false }

        let view: UInt64 = 1 << 10
        let send: UInt64 = 1 << 11
        let sendInThreads: UInt64 = 1 << 38
        let isThread = [10, 11, 12].contains(ch.type)
        var target = ch
        if isThread, let pid = ch.parent_id, let parent = guildChannels[gid]?.first(where: { $0.id == pid }) {
            target = parent
        }
        guard let perms = Store.permissions(for: target, guild: guild, roles: roles, meId: me.id) else { return true }
        if perms == UInt64.max { return true }
        if (perms & view) == 0 { return false }
        return isThread ? (perms & sendInThreads) != 0 : (perms & send) != 0
    }

    // MARK: - Ники и цвета ролей на сервере

    /// Запрашивает у Discord участников (роли и ники) для авторов сообщений.
    func requestMembers(guildId: String, userIds: [String]) {
        var known = requestedMembers[guildId] ?? []
        let fresh = userIds.filter { !known.contains($0) && guildMembers[guildId]?[$0] == nil }
        guard !fresh.isEmpty else { return }
        for id in fresh { known.insert(id) }
        requestedMembers[guildId] = known
        for chunk in stride(from: 0, to: fresh.count, by: 100) {
            let part = Array(fresh[chunk..<min(chunk + 100, fresh.count)])
            let d: [String: Any] = [
                "guild_id": guildId,
                "user_ids": part,
                "presences": false,
                "limit": 0,
                "nonce": String(Int(Date().timeIntervalSince1970 * 1000))
            ]
            _ = gateway?.sendRaw(["op": 8, "d": d])
        }
    }

    fileprivate func applyMembersChunk(_ d: [String: Any]) {
        guard let gid = d["guild_id"] as? String, let members = d["members"] as? [[String: Any]] else { return }
        var map = guildMembers[gid] ?? [:]
        for m in members {
            guard let u = m["user"] as? [String: Any], let uid = u["id"] as? String else { continue }
            map[uid] = MemberInfo(nick: m["nick"] as? String, roles: m["roles"] as? [String] ?? [])
        }
        guildMembers[gid] = map
    }

    /// Цвет ника: цвет самой высокой роли пользователя, у которой он задан.
    func roleColor(guildId: String?, userId: String, fallbackRoles: [String]) -> Color? {
        guard let guildId, let roles = guildRoles[guildId] else { return nil }
        let ids = Set(guildMembers[guildId]?[userId]?.roles ?? fallbackRoles)
        guard !ids.isEmpty else { return nil }
        let best = roles
            .filter { ids.contains($0.id) && ($0.color ?? 0) > 0 }
            .max { ($0.position ?? 0) < ($1.position ?? 0) }
        guard let c = best?.color else { return nil }
        return Color(hex: UInt32(c))
    }

    /// Серверный ник, если он есть, иначе обычное имя.
    func guildNick(guildId: String?, user: User, fallbackNick: String?) -> String {
        if let guildId, let nick = guildMembers[guildId]?[user.id]?.nick, !nick.isEmpty { return nick }
        if let nick = fallbackNick, !nick.isEmpty { return nick }
        return user.displayName
    }

    // MARK: - Личные сообщения: последнее сообщение и порядок

    func noteDMMessage(_ msg: Message) {
        guard let idx = dms.firstIndex(where: { $0.id == msg.channel_id }) else { return }
        dmPreviews[msg.channel_id] = msg
        if idx != 0 {
            let ch = dms.remove(at: idx)
            dms.insert(ch, at: 0)
        }
    }

    func loadDMPreview(_ ch: Channel) async {
        guard let api, ch.last_message_id != nil else { return }
        if let cached = dmPreviews[ch.id], cached.id == ch.last_message_id { return }
        if dmPreviews[ch.id] != nil || previewInFlight.contains(ch.id) { return }
        previewInFlight.insert(ch.id)
        let limiter = previewLimiter
        await limiter.acquire()
        let list: [Message]? = try? await api.get("/channels/\(ch.id)/messages?limit=1")
        await limiter.release()
        previewInFlight.remove(ch.id)
        if let m = list?.first { dmPreviews[ch.id] = m }
    }

    func previewText(_ m: Message) -> String {
        var text = m.content
            .replacingOccurrences(of: "<a?:(\\w+):\\d+>", with: ":$1:", options: .regularExpression)
            .replacingOccurrences(of: "<@!?\\d+>", with: "@", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let a = m.attachments.first {
            if a.isVoice { text = "Голосовое сообщение" }
            else if a.isImage { text = "Фото" }
            else if a.isVideo { text = "Видео" }
            else { text = a.filename }
        }
        if text.isEmpty, m.forwarded != nil { text = "Пересланное сообщение" }
        if let me, m.author.id == me.id { text = "Вы: " + text }
        return text
    }

    // MARK: - Порядок серверов в левой колонке

    static func applySavedOrder(_ list: [Guild]) -> [Guild] {
        let saved = UserDefaults.standard.stringArray(forKey: "guildOrder") ?? []
        guard !saved.isEmpty else { return list }
        let index = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($1, $0) })
        return list.enumerated().sorted { a, b in
            let ia = index[a.element.id] ?? (1000 + a.offset)
            let ib = index[b.element.id] ?? (1000 + b.offset)
            return ia < ib
        }.map { $0.element }
    }

    func moveGuild(_ fromId: String, to toId: String) {
        guard let from = guilds.firstIndex(where: { $0.id == fromId }),
              let to = guilds.firstIndex(where: { $0.id == toId }),
              from != to else { return }
        let g = guilds.remove(at: from)
        guilds.insert(g, at: to)
    }

    func saveGuildOrder() {
        UserDefaults.standard.set(guilds.map { $0.id }, forKey: "guildOrder")
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

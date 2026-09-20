import Foundation
import SwiftUI
import SwiftOGG

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
            Task { await login(token: saved) }
        }
    }

    // MARK: - Вход / выход

    func login(token: String) async {
        let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\""))
        guard !clean.isEmpty else { return }
        isLoading = true
        error = nil
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
            Keychain.save(clean)
            startGateway(token: clean, session: api.session)
        } catch {
            self.error = error.localizedDescription
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
            Task { @MainActor in self?.voice.handle(t, d) }
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
            if let member: GuildMember = try? await api.get("/users/@me/guilds/\(guild.id)/member"),
               let ids = Store.viewableIDs(all, guild: guild, roles: Set(member.roles), meId: me.id) {
                viewable[guild.id] = ids
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

    func loadMessages(_ channelId: String, silent: Bool = false) async {
        guard let api else { return }
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

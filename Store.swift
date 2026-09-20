import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var me: User?
    @Published var guilds: [Guild] = []
    @Published var dms: [Channel] = []
    @Published var guildChannels: [String: [Channel]] = [:]
    @Published var messages: [String: [Message]] = [:]
    @Published var error: String?
    @Published var isLoading = false
    @Published var proxy: ProxySettings {
        didSet {
            if let data = try? JSONEncoder().encode(proxy) {
                UserDefaults.standard.set(data, forKey: "proxy")
            }
        }
    }

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
            Keychain.save(clean)
            startGateway(token: clean, session: api.session)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func logout() {
        gateway?.stop()
        gateway = nil
        api = nil
        me = nil
        guilds = []
        dms = []
        guildChannels = [:]
        messages = [:]
        Keychain.delete()
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
        gw.start()
        gateway = gw
    }

    /// Каналы сервера с учётом прав: скрываем то, что тебе недоступно.
    func loadGuildChannels(_ guild: Guild) async {
        guard let api, let me else { return }
        if guildChannels[guild.id] != nil { return }
        do {
            let all: [Channel] = try await api.get("/guilds/\(guild.id)/channels")
            var result = all
            if let member: GuildMember = try? await api.get("/users/@me/guilds/\(guild.id)/member") {
                result = Store.visible(all, guild: guild, roles: Set(member.roles), meId: me.id)
            }
            guildChannels[guild.id] = result
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func visible(_ all: [Channel], guild: Guild, roles: Set<String>, meId: String) -> [Channel] {
        guard let permStr = guild.permissions, let base = UInt64(permStr) else { return all }
        let admin: UInt64 = 1 << 3
        let view: UInt64 = 1 << 10
        if guild.owner == true || (base & admin) != 0 { return all }

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

        let visibleChannels = all.filter { !$0.isCategory && canView($0) }
        let visibleIDs = Set(visibleChannels.map { $0.id })
        let parents = Set(visibleChannels.compactMap { $0.parent_id })
        return all.filter { ch in
            ch.isCategory ? parents.contains(ch.id) : visibleIDs.contains(ch.id)
        }
    }

    func loadMessages(_ channelId: String, silent: Bool = false) async {
        guard let api else { return }
        do {
            let list: [Message] = try await api.get("/channels/\(channelId)/messages?limit=50")
            merge(list, into: channelId)
        } catch {
            if !silent { self.error = error.localizedDescription }
        }
    }

    func send(_ text: String, files: [UploadFile], to channelId: String) async -> Bool {
        guard let api else { return false }
        do {
            let m = try await api.sendMessage(channelId: channelId, content: text, files: files)
            merge([m], into: channelId)
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
}

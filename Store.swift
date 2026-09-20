import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var me: User?
    @Published var guilds: [Guild] = []
    @Published var dms: [Channel] = []
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

    func loadChannels(guildId: String) async -> [Channel] {
        guard let api else { return [] }
        do {
            let all: [Channel] = try await api.get("/guilds/\(guildId)/channels")
            return all
                .filter { $0.type == 0 || $0.type == 5 }
                .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    func loadMessages(_ channelId: String) async {
        guard let api else { return }
        do {
            let list: [Message] = try await api.get("/channels/\(channelId)/messages?limit=50")
            merge(list, into: channelId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(_ text: String, to channelId: String) async {
        guard let api else { return }
        let body: [String: Any] = [
            "content": text,
            "tts": false,
            "nonce": String(Int(Date().timeIntervalSince1970 * 1000))
        ]
        do {
            let m: Message = try await api.post("/channels/\(channelId)/messages", body: body)
            merge([m], into: channelId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func merge(_ new: [Message], into channelId: String) {
        var dict: [String: Message] = [:]
        for m in messages[channelId] ?? [] { dict[m.id] = m }
        for m in new { dict[m.id] = m }
        messages[channelId] = dict.values.sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
    }
}

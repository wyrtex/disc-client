import Foundation

struct User: Decodable, Identifiable {
    let id: String
    let username: String
    let global_name: String?
    let avatar: String?
    let bot: Bool?

    var displayName: String { global_name ?? username }

    func avatarURL(size: Int = 128) -> URL? {
        if let avatar, !avatar.isEmpty {
            return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).png?size=\(size)")
        }
        let idx = Int((UInt64(id) ?? 0) >> 22) % 6
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(idx).png")
    }
}

struct Guild: Decodable, Identifiable {
    let id: String
    let name: String
    let icon: String?
    let owner: Bool?
    let permissions: String?

    var iconURL: URL? {
        guard let icon else { return nil }
        return URL(string: "https://cdn.discordapp.com/icons/\(id)/\(icon).png?size=128")
    }

    var initials: String {
        let letters = name.split(separator: " ").compactMap { $0.first }
        return String(letters.prefix(3))
    }
}

struct GuildMember: Decodable {
    let roles: [String]
}

struct Overwrite: Decodable {
    let id: String
    let isMember: Bool
    let allow: UInt64
    let deny: UInt64

    enum CodingKeys: String, CodingKey { case id, type, allow, deny }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let t = try? c.decode(Int.self, forKey: .type) {
            isMember = (t == 1)
        } else if let s = try? c.decode(String.self, forKey: .type) {
            isMember = (s == "1" || s == "member")
        } else {
            isMember = false
        }
        let a = (try? c.decode(String.self, forKey: .allow)) ?? "0"
        let d = (try? c.decode(String.self, forKey: .deny)) ?? "0"
        allow = UInt64(a) ?? 0
        deny = UInt64(d) ?? 0
    }
}

struct Channel: Decodable, Identifiable, Hashable {
    let id: String
    let type: Int
    let name: String?
    let position: Int?
    let last_message_id: String?
    let recipients: [User]?
    let parent_id: String?
    let permission_overwrites: [Overwrite]?

    static func == (l: Channel, r: Channel) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var title: String {
        if let name, !name.isEmpty { return name }
        let names = (recipients ?? []).map { $0.displayName }
        return names.isEmpty ? "Чат" : names.joined(separator: ", ")
    }

    var isCategory: Bool { type == 4 }
    var isVoice: Bool { type == 2 || type == 13 }
    var canOpen: Bool { type == 0 || type == 5 || type == 1 || type == 3 }

    var icon: String {
        switch type {
        case 1, 3: return "at"
        case 2: return "speaker.wave.2.fill"
        case 5: return "megaphone.fill"
        case 13: return "person.wave.2.fill"
        case 15: return "text.bubble.fill"
        default: return "number"
        }
    }
}

struct ChannelGroup: Identifiable {
    let id: String
    let category: Channel?
    let channels: [Channel]

    static func build(_ all: [Channel]) -> [ChannelGroup] {
        func order(_ a: Channel, _ b: Channel) -> Bool {
            let ga = a.isVoice ? 1 : 0
            let gb = b.isVoice ? 1 : 0
            if ga != gb { return ga < gb }
            return (a.position ?? 0) < (b.position ?? 0)
        }
        let shown: Set<Int> = [0, 2, 5, 13, 15]
        let cats = all.filter { $0.isCategory }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        let others = all.filter { !$0.isCategory && shown.contains($0.type) }

        var result: [ChannelGroup] = []
        let loose = others.filter { $0.parent_id == nil }.sorted(by: order)
        if !loose.isEmpty {
            result.append(ChannelGroup(id: "loose", category: nil, channels: loose))
        }
        for c in cats {
            let kids = others.filter { $0.parent_id == c.id }.sorted(by: order)
            if !kids.isEmpty {
                result.append(ChannelGroup(id: c.id, category: c, channels: kids))
            }
        }
        return result
    }
}

struct Attachment: Decodable, Identifiable {
    let id: String
    let filename: String
    let url: String
    let size: Int?
    let width: Int?
    let height: Int?
    let content_type: String?

    var isImage: Bool {
        if let t = content_type { return t.hasPrefix("image/") }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
    }

    var isVideo: Bool { content_type?.hasPrefix("video/") ?? false }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size ?? 0), countStyle: .file)
    }
}

struct ReplyRef: Decodable {
    let id: String
    let content: String
    let author: User

    enum CodingKeys: String, CodingKey { case id, content, author }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        author = try c.decode(User.self, forKey: .author)
    }
}

struct Message: Decodable, Identifiable {
    let id: String
    let channel_id: String
    let content: String
    let author: User
    let timestamp: String
    let attachments: [Attachment]
    let mentions: [User]
    let reply: ReplyRef?
    let date: Date?

    enum CodingKeys: String, CodingKey {
        case id, channel_id, content, author, timestamp, attachments, mentions, referenced_message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        channel_id = try c.decode(String.self, forKey: .channel_id)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        author = try c.decode(User.self, forKey: .author)
        let ts = try c.decode(String.self, forKey: .timestamp)
        timestamp = ts
        attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        mentions = (try? c.decode([User].self, forKey: .mentions)) ?? []
        reply = try? c.decode(ReplyRef.self, forKey: .referenced_message)
        date = Message.iso1.date(from: ts) ?? Message.iso2.date(from: ts)
    }

    private static let iso1: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso2: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    var timeText: String {
        guard let d = date else { return "" }
        if Calendar.current.isDateInToday(d) { return "Сегодня, " + Message.hm.string(from: d) }
        if Calendar.current.isDateInYesterday(d) { return "Вчера, " + Message.hm.string(from: d) }
        return Message.full.string(from: d)
    }
}

import Foundation

// MARK: - Хелперы

func snowflakeDate(_ id: String) -> Date? {
    guard let v = UInt64(id) else { return nil }
    return Date(timeIntervalSince1970: Double(v >> 22) / 1000 + 1_420_070_400)
}

func formatDate(_ d: Date?) -> String {
    guard let d else { return "—" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateStyle = .medium
    f.timeStyle = .none
    return f.string(from: d)
}

func relativeString(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "ru_RU")
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: - Пользователи и серверы

struct User: Decodable, Identifiable {
    let id: String
    let username: String
    let global_name: String?
    let avatar: String?
    let bot: Bool?
    let banner: String?
    let accent_color: Int?
    let primary_guild: PrimaryGuild?

    var displayName: String { global_name ?? username }

    func avatarURL(size: Int = 128) -> URL? {
        if let avatar, !avatar.isEmpty {
            return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).png?size=\(size)")
        }
        let idx = Int((UInt64(id) ?? 0) >> 22) % 6
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(idx).png")
    }

    func bannerURL(size: Int = 600) -> URL? {
        guard let banner, !banner.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/banners/\(id)/\(banner).png?size=\(size)")
    }
}

/// Клановый тег пользователя (значок и 4 буквы рядом с ником).
struct PrimaryGuild: Decodable {
    let identity_guild_id: String?
    let tag: String?
    let badge: String?

    var badgeURL: URL? {
        guard let g = identity_guild_id, let b = badge else { return nil }
        return URL(string: "https://cdn.discordapp.com/guild-tag-badges/\(g)/\(b).png?size=64")
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

struct GuildDetail: Decodable {
    let id: String
    let name: String
    let icon: String?
    let banner: String?
    let description: String?
    let approximate_member_count: Int?
    let approximate_presence_count: Int?
    let premium_subscription_count: Int?
    let premium_tier: Int?

    var bannerURL: URL? {
        guard let banner, !banner.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/banners/\(id)/\(banner).png?size=600")
    }
}

struct GuildRole: Decodable, Identifiable {
    let id: String
    let name: String
    let color: Int?
    let position: Int?
}

struct GuildMember: Decodable {
    let roles: [String]
    let communication_disabled_until: String?
}

struct GuildEmoji: Decodable, Identifiable {
    let id: String
    let name: String
    let animated: Bool?
    var ref: EmojiRef { EmojiRef(id: id, name: name, animated: animated) }
}

// MARK: - Профиль пользователя

struct UserProfileInfo: Decodable {
    let bio: String?
    let pronouns: String?
}

struct MutualGuild: Decodable {
    let id: String
}

struct ProfileBadge: Decodable, Identifiable {
    let id: String
    let description: String?
    let icon: String

    var url: URL? { URL(string: "https://cdn.discordapp.com/badge-icons/\(icon).png") }
}

struct GuildMemberInfo: Decodable {
    let roles: [String]?
    let joined_at: String?
    let nick: String?

    var joinedDate: Date? {
        guard let joined_at else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f1.date(from: joined_at) ?? f2.date(from: joined_at)
    }
}

struct ProfileResponse: Decodable {
    let user: User?
    let user_profile: UserProfileInfo?
    let mutual_guilds: [MutualGuild]?
    let guild_member: GuildMemberInfo?
    let badges: [ProfileBadge]?
    let mutual_friends_count: Int?

    enum CodingKeys: String, CodingKey {
        case user, user_profile, mutual_guilds, guild_member, badges, mutual_friends_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try? c.decode(User.self, forKey: .user)
        user_profile = try? c.decode(UserProfileInfo.self, forKey: .user_profile)
        mutual_guilds = try? c.decode([MutualGuild].self, forKey: .mutual_guilds)
        guild_member = try? c.decode(GuildMemberInfo.self, forKey: .guild_member)
        badges = try? c.decode([ProfileBadge].self, forKey: .badges)
        mutual_friends_count = try? c.decode(Int.self, forKey: .mutual_friends_count)
    }
}

// MARK: - Каналы

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
    let guild_id: String?
    let owner_id: String?
    let message_count: Int?
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

    var icon: String {
        switch type {
        case 1, 3: return "at"
        case 2: return "speaker.wave.2.fill"
        case 5: return "megaphone.fill"
        case 10, 11, 12: return "text.bubble.fill"
        case 13: return "person.wave.2.fill"
        case 15: return "bubble.left.and.bubble.right.fill"
        default: return "number"
        }
    }
}

struct ThreadSearchResult: Decodable {
    let threads: [Channel]
    let first_messages: [Message]
    let has_more: Bool

    enum CodingKeys: String, CodingKey { case threads, first_messages, has_more }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = (try? c.decode([Channel].self, forKey: .threads)) ?? []
        first_messages = (try? c.decode([Message].self, forKey: .first_messages)) ?? []
        has_more = (try? c.decode(Bool.self, forKey: .has_more)) ?? false
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

// MARK: - Сообщения

struct Attachment: Decodable, Identifiable {
    let id: String
    let filename: String
    let url: String
    let size: Int?
    let width: Int?
    let height: Int?
    let content_type: String?
    let duration_secs: Double?
    let waveform: String?
    let proxy_url: String?

    var isVoice: Bool { waveform != nil }

    var waveformBytes: [UInt8] {
        guard let waveform, let d = Data(base64Encoded: waveform) else { return [] }
        return [UInt8](d)
    }

    /// Столбики для отрисовки голосового сообщения, значения 0...1.
    func bars(_ n: Int) -> [Double] {
        let b = waveformBytes
        guard !b.isEmpty, n > 0 else { return Array(repeating: 0.3, count: max(n, 0)) }
        return (0..<n).map { i in
            let start = i * b.count / n
            let end = max(start + 1, (i + 1) * b.count / n)
            let slice = b[start..<min(end, b.count)]
            let sum = slice.reduce(0) { $0 + Int($1) }
            let avg = Double(sum) / Double(max(1, slice.count))
            return max(0.08, min(1, avg / 255))
        }
    }

    var isImage: Bool {
        if let t = content_type { return t.hasPrefix("image/") }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
    }

    /// Видео, которое умеет играть iOS. У части вложений тип не указан, тогда смотрим на расширение.
    var isVideo: Bool {
        if let t = content_type, t.hasPrefix("video/") {
            return !t.contains("webm") && !t.contains("matroska")
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(ext)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size ?? 0), countStyle: .file)
    }
}

struct EmojiRef: Decodable, Hashable {
    let id: String?
    let name: String?
    let animated: Bool?

    init(id: String?, name: String?, animated: Bool? = nil) {
        self.id = id
        self.name = name
        self.animated = animated
    }

    static func == (l: EmojiRef, r: EmojiRef) -> Bool {
        if l.id != nil || r.id != nil { return l.id == r.id }
        return l.name == r.name
    }

    func hash(into hasher: inout Hasher) {
        if let id { hasher.combine(id) } else { hasher.combine(name) }
    }

    var apiPath: String {
        let raw: String
        if let id { raw = "\(name ?? "e"):\(id)" } else { raw = name ?? "" }
        return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    var inlineText: String {
        if let id { return "<\(animated == true ? "a" : ""):\(name ?? "e"):\(id)>" }
        return name ?? ""
    }

    var imageURL: URL? {
        guard let id else { return nil }
        return URL(string: "https://cdn.discordapp.com/emojis/\(id).png?size=64")
    }
}

struct Reaction: Decodable, Identifiable {
    let count: Int
    let me: Bool
    let emoji: EmojiRef

    var id: String { emoji.apiPath }

    enum CodingKeys: String, CodingKey { case count, me, emoji }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
        me = (try? c.decode(Bool.self, forKey: .me)) ?? false
        emoji = try c.decode(EmojiRef.self, forKey: .emoji)
    }
}

struct ForwardedContent: Decodable {
    let content: String
    let attachments: [Attachment]

    enum CodingKeys: String, CodingKey { case message }
    enum InnerKeys: String, CodingKey { case content, attachments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let inner = try c.nestedContainer(keyedBy: InnerKeys.self, forKey: .message)
        content = (try? inner.decode(String.self, forKey: .content)) ?? ""
        attachments = (try? inner.decode([Attachment].self, forKey: .attachments)) ?? []
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
    let mention_roles: [String]
    let mention_everyone: Bool
    let member_roles: [String]
    let member_nick: String?
    let embeds: [Embed]
    let components: [Component]
    let stickers: [StickerItem]
    let flags: Int
    let application_id: String?
    let reply: ReplyRef?
    let reactions: [Reaction]
    let forwarded: ForwardedContent?
    let date: Date?

    enum CodingKeys: String, CodingKey {
        case id, channel_id, content, author, timestamp, attachments, mentions
        case mention_roles, mention_everyone, member
        case embeds, components, sticker_items, flags, application_id
        case referenced_message, reactions, message_snapshots
    }

    enum MemberKeys: String, CodingKey { case roles, nick }

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
        mention_roles = (try? c.decode([String].self, forKey: .mention_roles)) ?? []
        mention_everyone = (try? c.decode(Bool.self, forKey: .mention_everyone)) ?? false
        embeds = (try? c.decode([Embed].self, forKey: .embeds)) ?? []
        components = (try? c.decode([Component].self, forKey: .components)) ?? []
        stickers = (try? c.decode([StickerItem].self, forKey: .sticker_items)) ?? []
        flags = (try? c.decode(Int.self, forKey: .flags)) ?? 0
        application_id = try? c.decodeIfPresent(String.self, forKey: .application_id)
        if let mc = try? c.nestedContainer(keyedBy: MemberKeys.self, forKey: .member) {
            member_roles = (try? mc.decode([String].self, forKey: .roles)) ?? []
            member_nick = try? mc.decodeIfPresent(String.self, forKey: .nick)
        } else {
            member_roles = []
            member_nick = nil
        }
        reply = try? c.decode(ReplyRef.self, forKey: .referenced_message)
        reactions = (try? c.decode([Reaction].self, forKey: .reactions)) ?? []
        forwarded = (try? c.decode([ForwardedContent].self, forKey: .message_snapshots))?.first
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

/// Результат поиска участников сервера (для подсказок при вводе @).
struct MemberSearchItem: Decodable {
    let user: User
    let nick: String?
}


// MARK: - Эмбеды, стикеры и компоненты сообщений

struct EmbedMedia: Decodable {
    let url: String?
    let proxy_url: String?
    let width: Int?
    let height: Int?

    /// Лучше брать адрес через прокси Discord: он стабильнее и отдаёт нужный формат.
    var best: URL? {
        if let p = proxy_url, let u = URL(string: p) { return u }
        if let s = url, let u = URL(string: s) { return u }
        return nil
    }
}

struct EmbedFooter: Decodable {
    let text: String?
    let icon_url: String?
}

struct EmbedProvider: Decodable {
    let name: String?
}

struct EmbedAuthor: Decodable {
    let name: String?
    let url: String?
    let icon_url: String?
}

struct EmbedField: Decodable {
    let name: String
    let value: String
    let inline: Bool?
}

struct Embed: Decodable {
    let type: String?
    let title: String?
    let description: String?
    let url: String?
    let color: Int?
    let timestamp: String?
    let footer: EmbedFooter?
    let image: EmbedMedia?
    let thumbnail: EmbedMedia?
    let video: EmbedMedia?
    let provider: EmbedProvider?
    let author: EmbedAuthor?
    let fields: [EmbedField]?
}

struct StickerItem: Decodable, Identifiable {
    let id: String
    let name: String
    let format_type: Int

    /// PNG и APNG показываем как картинку, GIF как анимацию. Lottie (3) не поддерживаем.
    var url: URL? {
        switch format_type {
        case 1, 2: return URL(string: "https://media.discordapp.net/stickers/\(id).png?size=160")
        case 4: return URL(string: "https://media.discordapp.net/stickers/\(id).gif?size=160")
        default: return nil
        }
    }
}

struct SelectOption: Decodable, Identifiable {
    let label: String
    let value: String
    let description: String?
    let emoji: EmojiRef?
    let isDefault: Bool?

    var id: String { value }

    enum CodingKeys: String, CodingKey {
        case label, value, description, emoji
        case isDefault = "default"
    }
}

struct GalleryItem: Decodable {
    let media: EmbedMedia
    let description: String?
}

struct FileRef: Decodable {
    let url: String?
}

/// Компонент сообщения бота: кнопка, меню, а также блоки нового формата (текст, контейнер, галерея и т.д.).
struct Component: Decodable, Identifiable {
    let uid = UUID()
    var id: UUID { uid }

    let type: Int
    let style: Int?
    let label: String?
    let emoji: EmojiRef?
    let custom_id: String?
    let url: String?
    let disabled: Bool
    let children: [Component]
    let options: [SelectOption]
    let placeholder: String?
    let content: String?
    let accessory: [Component]
    let mediaItems: [GalleryItem]
    let divider: Bool
    let accent_color: Int?
    let fileURL: String?

    enum CodingKeys: String, CodingKey {
        case type, style, label, emoji, custom_id, url, disabled, components
        case options, placeholder, content, accessory, items, media
        case divider, accent_color, file
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(Int.self, forKey: .type)
        style = try? c.decode(Int.self, forKey: .style)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        emoji = try? c.decode(EmojiRef.self, forKey: .emoji)
        custom_id = try? c.decodeIfPresent(String.self, forKey: .custom_id)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        disabled = (try? c.decode(Bool.self, forKey: .disabled)) ?? false
        children = (try? c.decode([Component].self, forKey: .components)) ?? []
        options = (try? c.decode([SelectOption].self, forKey: .options)) ?? []
        placeholder = try? c.decodeIfPresent(String.self, forKey: .placeholder)
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        if let a = try? c.decode(Component.self, forKey: .accessory) {
            accessory = [a]
        } else {
            accessory = []
        }
        var items = (try? c.decode([GalleryItem].self, forKey: .items)) ?? []
        if let m = try? c.decode(EmbedMedia.self, forKey: .media) {
            items = [GalleryItem(media: m, description: nil)]
        }
        mediaItems = items
        divider = (try? c.decode(Bool.self, forKey: .divider)) ?? true
        accent_color = try? c.decodeIfPresent(Int.self, forKey: .accent_color)
        if let f = try? c.decode(FileRef.self, forKey: .file) {
            fileURL = f.url
        } else {
            fileURL = nil
        }
    }
}

import SwiftUI

/// Ограничитель числа одновременных задач (чтобы аватарки не душили канал, по которому идёт голос).
actor AsyncLimiter {
    private var running = 0
    private var limit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func setLimit(_ n: Int) { limit = max(1, n) }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            let w = waiters.removeFirst()
            w.resume()
        }
    }
}

final class ImageLoader {
    static let shared = ImageLoader()
    var session: URLSession = .shared
    private let cache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private let limiter = AsyncLimiter(limit: 6)

    init() {
        cache.countLimit = 500
    }

    /// Во время голосового звонка грузим меньше картинок одновременно.
    func setLimit(_ n: Int) {
        let l = limiter
        Task { await l.setLimit(n) }
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }

        lock.lock()
        if let existing = inflight[url] {
            lock.unlock()
            return await existing.value
        }
        let s = session
        let l = limiter
        let task = Task<UIImage?, Never> {
            await l.acquire()
            let result = await ImageLoader.fetch(url, session: s)
            await l.release()
            return result
        }
        inflight[url] = task
        lock.unlock()

        let img = await task.value
        if let img { cache.setObject(img, forKey: url as NSURL) }
        lock.lock()
        inflight[url] = nil
        lock.unlock()
        return img
    }

    private static func fetch(_ url: URL, session: URLSession) async -> UIImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .returnCacheDataElseLoad
        for attempt in 0..<2 {
            if let (data, resp) = try? await session.data(for: req) {
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
                if ok, let img = UIImage(data: data) { return img }
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        return nil
    }

    /// Кастомный эмодзи, уменьшенный до нужного размера в пунктах.
    func emojiImage(id: String, points: CGFloat) async -> UIImage? {
        guard let url = URL(string: "https://cdn.discordapp.com/emojis/\(id).png?size=96"),
              let img = await image(for: url) else { return nil }
        let size = CGSize(width: points, height: points)
        return UIGraphicsImageRenderer(size: size).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let placeholder: Placeholder
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await ImageLoader.shared.image(for: url)
        }
    }
}

struct AvatarView: View {
    let user: User?
    var size: CGFloat = 40

    var body: some View {
        RemoteImage(url: user?.avatarURL(size: size > 48 ? 256 : 128)) {
            Circle().fill(Theme.blurple)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct GuildIcon: View {
    let guild: Guild
    let selected: Bool

    var body: some View {
        RemoteImage(url: guild.iconURL) {
            ZStack {
                Theme.chat
                Text(guild.initials)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(4)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: selected ? 16 : 24))
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

// MARK: - Разметка Discord

enum DiscordText {
    static func attributed(_ raw: String, mentions: [User]) -> AttributedString {
        var s = raw
        for u in mentions {
            s = s.replacingOccurrences(of: "<@\(u.id)>", with: "@\(u.displayName)")
            s = s.replacingOccurrences(of: "<@!\(u.id)>", with: "@\(u.displayName)")
        }
        // Голые ссылки делаем кликабельными
        s = s.replacingOccurrences(
            of: "(?<![\\(<\\[])https?://[^\\s<>\\)\\]]+",
            with: "[$0]($0)",
            options: .regularExpression
        )
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: options) { return a }
        return AttributedString(raw)
    }
}

// MARK: - Текущий сервер в окружении

private struct GuildIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var currentGuildId: String? {
        get { self[GuildIDKey.self] }
        set { self[GuildIDKey.self] = newValue }
    }
}

/// Текст сообщения: разметка, кастомные эмодзи картинками, упоминания (пользователи, роли, каналы), время.
struct RichText: View {
    let raw: String
    let mentions: [User]
    @EnvironmentObject var store: Store
    @Environment(\.currentGuildId) private var guildId
    @State private var images: [String: UIImage] = [:]

    enum Token {
        case text(String)
        case emoji(id: String, name: String)
        case mention(kind: String, id: String)
        case time(seconds: Double, style: String)

        var isEmoji: Bool {
            if case .emoji = self { return true }
            return false
        }
    }

    private static let tokenRegex = try? NSRegularExpression(
        pattern: "<a?:(\\w+):(\\d+)>|<@!?(\\d+)>|<@&(\\d+)>|<#(\\d+)>|<t:(-?\\d+)(?::([a-zA-Z]))?>"
    )

    static func tokenize(_ s: String) -> [Token] {
        guard let re = tokenRegex else { return [.text(s)] }
        let ns = s as NSString
        var out: [Token] = []
        var last = 0

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last))))
            }
            if let id = group(m, 2), let name = group(m, 1) {
                out.append(.emoji(id: id, name: name))
            } else if let id = group(m, 3) {
                out.append(.mention(kind: "u", id: id))
            } else if let id = group(m, 4) {
                out.append(.mention(kind: "r", id: id))
            } else if let id = group(m, 5) {
                out.append(.mention(kind: "c", id: id))
            } else if let t = group(m, 6), let secs = Double(t) {
                out.append(.time(seconds: secs, style: group(m, 7) ?? "f"))
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }

    private var jumbo: Bool {
        let t = RichText.tokenize(raw)
        let count = t.filter { $0.isEmoji }.count
        let onlyEmoji = t.allSatisfy { tok in
            switch tok {
            case .emoji: return true
            case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
        return count > 0 && count <= 6 && onlyEmoji
    }

    var body: some View {
        let size: CGFloat = jumbo ? 44 : 22
        build()
            .font(.system(size: 16))
            .foregroundStyle(Theme.normalText)
            .tint(Theme.link)
            .task(id: raw) {
                for case .emoji(let id, _) in RichText.tokenize(raw) where images[id] == nil {
                    if let img = await ImageLoader.shared.emojiImage(id: id, points: size) {
                        images[id] = img
                    }
                }
            }
    }

    private func mentionName(kind: String, id: String) -> String {
        switch kind {
        case "u":
            if let u = mentions.first(where: { $0.id == id }) { return "@" + u.displayName }
            if let u = store.voiceUsers[id] { return "@" + u.displayName }
            if let me = store.me, me.id == id { return "@" + me.displayName }
            return "@пользователь"
        case "r":
            if let gid = guildId,
               let role = store.guildRoles[gid]?.first(where: { $0.id == id }) {
                return "@" + role.name
            }
            return "@роль"
        default:
            if let name = store.channelName(id) { return "#" + name }
            return "#канал"
        }
    }

    private static let timeDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func timeString(_ secs: Double, style: String) -> String {
        let d = Date(timeIntervalSince1970: secs)
        let f = DateFormatter()
        switch style {
        case "R":
            return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
        case "t":
            f.dateStyle = .none; f.timeStyle = .short
        case "T":
            f.dateStyle = .none; f.timeStyle = .medium
        case "d":
            f.dateStyle = .short; f.timeStyle = .none
        case "D":
            f.dateStyle = .long; f.timeStyle = .none
        case "F":
            f.dateStyle = .full; f.timeStyle = .short
        default:
            f.dateStyle = .long; f.timeStyle = .short
        }
        return f.string(from: d)
    }

    private func build() -> Text {
        var result = Text("")
        for t in RichText.tokenize(raw) {
            switch t {
            case .text(let s):
                result = result + Text(DiscordText.attributed(s, mentions: mentions))
            case .emoji(let id, let name):
                if let img = images[id] {
                    result = result + Text(Image(uiImage: img))
                } else {
                    result = result + Text(":\(name):")
                }
            case .mention(let kind, let id):
                var a = AttributedString(mentionName(kind: kind, id: id))
                a.foregroundColor = Color(hex: 0xC9CDFB)
                a.backgroundColor = Theme.blurple.opacity(0.3)
                result = result + Text(a)
            case .time(let secs, let style):
                var a = AttributedString(timeString(secs, style: style))
                a.backgroundColor = Color.white.opacity(0.12)
                result = result + Text(a)
            }
        }
        return result
    }
}

// MARK: - Переносящаяся раскладка (для реакций и ролей)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct EmojiView: View {
    let emoji: EmojiRef
    var size: CGFloat = 18

    var body: some View {
        if let url = emoji.imageURL {
            RemoteImage(url: url, contentMode: .fit) { Color.clear }
                .frame(width: size, height: size)
        } else {
            Text(emoji.name ?? "")
                .font(.system(size: size - 2))
        }
    }
}

struct ReactionChip: View {
    let reaction: Reaction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                EmojiView(emoji: reaction.emoji, size: 18)
                Text("\(reaction.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(reaction.me ? Theme.text : Theme.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(reaction.me ? Theme.blurple.opacity(0.3) : Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(reaction.me ? Theme.blurple : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

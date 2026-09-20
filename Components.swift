import SwiftUI

final class ImageLoader {
    static let shared = ImageLoader()
    var session: URLSession = .shared
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        do {
            let (data, _) = try await session.data(from: url)
            guard let img = UIImage(data: data) else { return nil }
            cache.setObject(img, forKey: url as NSURL)
            return img
        } catch {
            return nil
        }
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

/// Текст сообщения: разметка + кастомные эмодзи картинками прямо в строке.
struct RichText: View {
    let raw: String
    let mentions: [User]
    @State private var images: [String: UIImage] = [:]

    enum Token {
        case text(String)
        case emoji(id: String, name: String)

        var isEmoji: Bool {
            if case .emoji = self { return true }
            return false
        }
    }

    static func tokenize(_ s: String) -> [Token] {
        guard let re = try? NSRegularExpression(pattern: "<a?:(\\w+):(\\d+)>") else { return [.text(s)] }
        let ns = s as NSString
        var out: [Token] = []
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last))))
            }
            out.append(.emoji(id: ns.substring(with: m.range(at: 2)), name: ns.substring(with: m.range(at: 1))))
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

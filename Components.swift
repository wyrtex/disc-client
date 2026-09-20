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

enum DiscordText {
    static func attributed(_ raw: String, mentions: [User]) -> AttributedString {
        var s = raw
        for u in mentions {
            s = s.replacingOccurrences(of: "<@\(u.id)>", with: "@\(u.displayName)")
            s = s.replacingOccurrences(of: "<@!\(u.id)>", with: "@\(u.displayName)")
        }
        // Кастомные эмодзи <:name:id> -> :name:
        s = s.replacingOccurrences(of: "<a?:(\\w+):\\d+>", with: ":$1:", options: .regularExpression)
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

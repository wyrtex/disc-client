import SwiftUI

struct EmojiCategory {
    let title: String
    let items: [String]
}

enum EmojiData {
    static let categories: [EmojiCategory] = [
        EmojiCategory(title: "Смайлы", items: [
            "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰",
            "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥳", "😏", "😒",
            "😞", "😔", "😟", "😕", "🙁", "😣", "😖", "😫", "😩", "🥺", "😢", "😭", "😤", "😠", "😡", "🤬",
            "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓", "🤗", "🤔", "🤭", "🤫", "🤥", "😶", "😐",
            "😑", "😬", "🙄", "😯", "😦", "😧", "😮", "😲", "🥱", "😴", "🤤", "😪", "😵", "🤐", "🥴", "🤢",
            "🤮", "🤧", "😷", "🤒", "🤕", "😈", "👿", "💀", "👻", "👽", "🤖", "💩"
        ]),
        EmojiCategory(title: "Жесты", items: [
            "👍", "👎", "👌", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇", "☝️", "✋", "🤚", "🖐️",
            "🖖", "👋", "🤝", "🙏", "👏", "🙌", "👐", "🤲", "💪", "🫶", "🫡", "👀", "🧠", "👑"
        ]),
        EmojiCategory(title: "Сердца и символы", items: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "💕", "💞", "💓", "💗", "💖", "💘",
            "🔥", "✨", "⭐", "🌟", "💥", "💯", "✅", "❌", "❓", "❗", "⚠️", "💤", "💢", "💫"
        ]),
        EmojiCategory(title: "Разное", items: [
            "🎉", "🎊", "🎁", "🏆", "🎮", "🎧", "🎵", "🎶", "📷", "💻", "📱", "🚀", "🌈", "☀️", "🌙", "⚡",
            "❄️", "🍕", "🍔", "🍟", "🍿", "☕", "🍺", "🐶", "🐱", "🐼", "🦊", "🐸", "🐵", "🦄", "🌹", "🎂"
        ])
    ]
}

/// Выбор эмодзи: эмодзи текущего сервера сверху, обычные ниже.
struct EmojiPickerView: View {
    @EnvironmentObject var store: Store
    let guildId: String?
    let onPick: (EmojiRef) -> Void

    private let columns = [GridItem(.adaptive(minimum: 42), spacing: 4)]

    private var serverEmojis: [GuildEmoji] {
        guard let guildId else { return [] }
        return store.guildEmojis[guildId] ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !serverEmojis.isEmpty {
                    title("Этот сервер")
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(serverEmojis) { e in
                            Button {
                                onPick(e.ref)
                            } label: {
                                RemoteImage(url: e.ref.imageURL, contentMode: .fit) { Color.clear }
                                    .frame(width: 34, height: 34)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(EmojiData.categories, id: \.title) { cat in
                    title(cat.title)
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(cat.items, id: \.self) { s in
                            Button {
                                onPick(EmojiRef(id: nil, name: s))
                            } label: {
                                Text(s)
                                    .font(.system(size: 30))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
        }
        .task {
            if let guildId { await store.loadEmojis(guildId) }
        }
    }

    private func title(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.muted)
            .padding(.top, 6)
    }
}

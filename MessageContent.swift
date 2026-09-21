import SwiftUI
import AVKit
import ImageIO

// MARK: - Размеры медиа в сообщении

enum MediaMetrics {
    static var width: CGFloat { min(320, UIScreen.main.bounds.width - 110) }
}

// MARK: - Всё вложенное в сообщение: вложения, эмбеды, стикеры, компоненты

struct MessageMedia: View {
    let message: Message
    let onImage: (URL) -> Void
    let onVideo: (URL) -> Void

    private var gridItems: [GridMedia] {
        message.attachments.compactMap { a in
            guard !a.isVoice, (a.isImage || a.isVideo), let url = URL(string: a.url) else { return nil }
            let display = a.proxy_url.flatMap { URL(string: $0) } ?? url
            let name = a.filename.lowercased()
            let gif = (a.content_type == "image/gif") || name.hasSuffix(".gif")
            return GridMedia(
                id: a.id,
                url: url,
                displayURL: display,
                width: a.width,
                height: a.height,
                isVideo: a.isVideo,
                isGif: a.isImage && gif
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.attachments.filter { $0.isVoice }) { a in
                VoiceMessageView(attachment: a)
            }

            let items = gridItems
            if !items.isEmpty {
                MediaGrid(items: items, onImage: onImage, onVideo: onVideo)
            }

            ForEach(message.attachments.filter { !$0.isVoice && !$0.isImage && !$0.isVideo }) { a in
                AttachmentView(attachment: a, onImage: onImage)
            }

            ForEach(message.stickers) { s in
                StickerView(sticker: s)
            }

            ForEach(Array(message.embeds.enumerated()), id: \.offset) { _, e in
                EmbedView(embed: e, onImage: onImage, onVideo: onVideo)
            }

            if !message.components.isEmpty {
                ComponentsView(message: message, components: message.components)
            }
        }
    }
}

// MARK: - Сетка медиа (как в Discord)

struct GridMedia: Identifiable {
    let id: String
    let url: URL
    let displayURL: URL
    let width: Int?
    let height: Int?
    let isVideo: Bool
    let isGif: Bool
}

struct MediaGrid: View {
    let items: [GridMedia]
    let onImage: (URL) -> Void
    let onVideo: (URL) -> Void

    private var w: CGFloat { MediaMetrics.width }
    private var half: CGFloat { (w - 4) / 2 }
    private var third: CGFloat { (w - 8) / 3 }

    var body: some View {
        Group {
            switch items.count {
            case 1:
                single(items[0])
            case 2:
                HStack(spacing: 4) {
                    cell(items[0], half, half)
                    cell(items[1], half, half)
                }
            case 3:
                HStack(spacing: 4) {
                    cell(items[0], half, w)
                    VStack(spacing: 4) {
                        cell(items[1], half, half)
                        cell(items[2], half, half)
                    }
                }
            case 4:
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        cell(items[0], half, half)
                        cell(items[1], half, half)
                    }
                    HStack(spacing: 4) {
                        cell(items[2], half, half)
                        cell(items[3], half, half)
                    }
                }
            default:
                manyItems
            }
        }
    }

    private var manyItems: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                cell(items[0], half, half)
                cell(items[1], half, half)
            }
            ForEach(0..<((items.count - 2 + 2) / 3), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rowItems(row)) { m in
                        cell(m, third, third)
                    }
                }
            }
        }
    }

    private func rowItems(_ row: Int) -> [GridMedia] {
        let start = 2 + row * 3
        let end = min(start + 3, items.count)
        return start < end ? Array(items[start..<end]) : []
    }

    private func single(_ m: GridMedia) -> some View {
        var cw = w
        var ch = w * 0.75
        if let mw = m.width, let mh = m.height, mw > 0, mh > 0 {
            let scale = min(1, w / CGFloat(mw), 360 / CGFloat(mh))
            cw = max(90, CGFloat(mw) * scale)
            ch = max(90, CGFloat(mh) * scale)
        }
        return cell(m, cw, ch)
    }

    private func cell(_ m: GridMedia, _ cw: CGFloat, _ ch: CGFloat) -> some View {
        ZStack {
            if m.isVideo {
                VideoPosterView(url: m.url)
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.55), in: Circle())
            } else if m.isGif {
                AnimatedGIF(url: m.displayURL)
            } else {
                RemoteImage(url: m.displayURL, contentMode: .fill) { Theme.input }
            }
        }
        .frame(width: cw, height: ch)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if m.isVideo { onVideo(m.url) } else { onImage(m.displayURL) }
        }
    }
}

// MARK: - Анимированный GIF

final class GIFContainerView: UIView {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct GIFRepresentable: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> GIFContainerView {
        let v = GIFContainerView()
        v.imageView.image = image
        return v
    }

    func updateUIView(_ uiView: GIFContainerView, context: Context) {
        if uiView.imageView.image !== image { uiView.imageView.image = image }
    }
}

struct AnimatedGIF: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                GIFRepresentable(image: image)
            } else {
                Theme.input
            }
        }
        .task(id: url) {
            image = await ImageLoader.shared.animatedImage(for: url)
        }
    }
}

// MARK: - Видео: превью, зацикленное и полноэкранное

@MainActor
final class VideoPosterCache {
    static let shared = VideoPosterCache()
    private let cache = NSCache<NSURL, UIImage>()
    private let limiter = AsyncLimiter(limit: 2)

    func poster(for url: URL) async -> UIImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        do {
            let result = try await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600))
            let img = UIImage(cgImage: result.image)
            cache.setObject(img, forKey: url as NSURL)
            return img
        } catch {
            return nil
        }
    }
}

struct VideoPosterView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(hex: 0x1E1F22)
            }
        }
        .task(id: url) {
            image = await VideoPosterCache.shared.poster(for: url)
        }
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Беззвучное зацикленное видео (gifv-эмбеды Tenor, Klipy и т.п.).
struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: url)
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        context.coordinator.player = player
        v.playerLayer.player = player
        player.play()
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
    }
}

/// Полноэкранный просмотр видео.
struct VideoViewer: View {
    @EnvironmentObject var store: Store
    let url: URL
    let onClose: () -> Void
    @State private var player = AVPlayer()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
        .onAppear {
            if !store.voice.isConnected {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
        .onDisappear { player.pause() }
    }
}

// MARK: - Стикеры

struct StickerView: View {
    let sticker: StickerItem

    var body: some View {
        if let url = sticker.url {
            if sticker.format_type == 4 {
                AnimatedGIF(url: url)
                    .frame(width: 140, height: 140)
            } else {
                RemoteImage(url: url, contentMode: .fit) { Color.clear }
                    .frame(width: 140, height: 140)
            }
        } else {
            Text("Стикер: \(sticker.name)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Эмбеды

struct EmbedView: View {
    let embed: Embed
    let onImage: (URL) -> Void
    let onVideo: (URL) -> Void

    private var isGifLike: Bool {
        guard let v = embed.video?.best else { return false }
        let ext = v.pathExtension.lowercased()
        if embed.type == "gifv" { return true }
        if embed.type == "video", ext == "mp4" {
            let provider = (embed.provider?.name ?? "").lowercased()
            if ["tenor", "klipy", "giphy"].contains(provider) { return true }
            if (embed.video?.width ?? 9999) <= 700 && embed.provider == nil { return true }
        }
        return false
    }

    var body: some View {
        if isGifLike, let url = embed.video?.best {
            gif(url)
        } else if embed.type == "image", let url = embed.thumbnail?.best ?? embed.image?.best {
            image(url)
        } else if embed.type == "video" {
            videoCard
        } else {
            card
        }
    }

    // GIF (gifv)

    private func gif(_ url: URL) -> some View {
        let dims = fit(embed.video?.width, embed.video?.height, maxW: MediaMetrics.width, maxH: 320)
        return LoopingVideoView(url: url)
            .frame(width: dims.width, height: dims.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                Text("GIF")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture { onVideo(url) }
    }

    // Картинка по ссылке

    private func image(_ url: URL) -> some View {
        let m = embed.thumbnail ?? embed.image
        let dims = fit(m?.width, m?.height, maxW: MediaMetrics.width, maxH: 360)
        return RemoteImage(url: url, contentMode: .fill) { Theme.input }
            .frame(width: dims.width, height: dims.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { onImage(url) }
    }

    // Видео (YouTube и т.п.): превью, по тапу открываем страницу

    private var videoCard: some View {
        let thumb = embed.thumbnail?.best
        let dims = fit(embed.thumbnail?.width ?? embed.video?.width, embed.thumbnail?.height ?? embed.video?.height, maxW: MediaMetrics.width, maxH: 220)
        return VStack(alignment: .leading, spacing: 4) {
            if let provider = embed.provider?.name {
                Text(provider).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if let title = embed.title {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.link).lineLimit(2)
            }
            ZStack {
                RemoteImage(url: thumb, contentMode: .fill) { Color(hex: 0x1E1F22) }
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .frame(width: dims.width, height: dims.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .frame(maxWidth: MediaMetrics.width + 20, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { colorBar }
        .onTapGesture { openLink() }
    }

    // Обычная карточка (embed бота, статья, ссылка)

    private var accent: Color {
        if let c = embed.color, c > 0 { return Color(hex: UInt32(c)) }
        return Color(hex: 0x1E1F22)
    }

    private var colorBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(accent)
            .frame(width: 4)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if let provider = embed.provider?.name, embed.author == nil {
                    Text(provider).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if let a = embed.author, let name = a.name {
                    HStack(spacing: 6) {
                        if let icon = a.icon_url.flatMap({ URL(string: $0) }) {
                            RemoteImage(url: icon) { Color.clear }
                                .frame(width: 20, height: 20)
                                .clipShape(Circle())
                        }
                        Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                }
                if let title = embed.title {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(embed.url != nil ? Theme.link : Theme.text)
                        .onTapGesture { openLink() }
                }
                if let d = embed.description, !d.isEmpty {
                    RichText(raw: d, mentions: [])
                }
                fieldsView
                if let big = embed.image?.best {
                    let dims = fit(embed.image?.width, embed.image?.height, maxW: MediaMetrics.width - 24, maxH: 320)
                    RemoteImage(url: big, contentMode: .fill) { Theme.input }
                        .frame(width: dims.width, height: dims.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { onImage(big) }
                }
                footerView
            }
            Spacer(minLength: 0)
            if embed.image == nil, let thumb = embed.thumbnail?.best {
                RemoteImage(url: thumb, contentMode: .fill) { Theme.input }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { onImage(thumb) }
            }
        }
        .padding(10)
        .padding(.leading, 4)
        .frame(maxWidth: MediaMetrics.width + 20, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { colorBar }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var fieldsView: some View {
        if let fields = embed.fields, !fields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                        RichText(raw: f.value, mentions: [])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        let text = footerText
        if !text.isEmpty {
            HStack(spacing: 6) {
                if let icon = embed.footer?.icon_url.flatMap({ URL(string: $0) }) {
                    RemoteImage(url: icon) { Color.clear }
                        .frame(width: 16, height: 16)
                        .clipShape(Circle())
                }
                Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var footerText: String {
        var parts: [String] = []
        if let t = embed.footer?.text, !t.isEmpty { parts.append(t) }
        if let ts = embed.timestamp, let d = Store.parseISO(ts) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateStyle = .medium
            f.timeStyle = .short
            parts.append(f.string(from: d))
        }
        return parts.joined(separator: " • ")
    }

    private func openLink() {
        if let s = embed.url, let u = URL(string: s) { UIApplication.shared.open(u) }
    }

    private func fit(_ w: Int?, _ h: Int?, maxW: CGFloat, maxH: CGFloat) -> CGSize {
        guard let w, let h, w > 0, h > 0 else { return CGSize(width: maxW, height: maxW * 0.6) }
        let scale = min(1, maxW / CGFloat(w), maxH / CGFloat(h))
        return CGSize(width: max(80, CGFloat(w) * scale), height: max(60, CGFloat(h) * scale))
    }
}

// MARK: - Кнопки и меню ботов

struct ComponentsView: View {
    let message: Message
    let components: [Component]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(components) { c in
                AnyView(ComponentNode(message: message, component: c))
            }
        }
    }
}

struct ComponentNode: View {
    let message: Message
    let component: Component

    var body: some View {
        switch component.type {
        case 1:
            FlowLayout(spacing: 6) {
                ForEach(component.children) { child in
                    AnyView(ComponentNode(message: message, component: child))
                }
            }
        case 2:
            ComponentButton(message: message, component: component)
        case 3:
            ComponentSelect(message: message, component: component)
        case 4, 5, 6, 7, 8:
            Text(component.placeholder ?? "Выбор пользователей, ролей и каналов пока не поддерживается")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(8)
                .background(Theme.input.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        case 9:
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(component.children) { child in
                        AnyView(ComponentNode(message: message, component: child))
                    }
                }
                Spacer(minLength: 0)
                ForEach(component.accessory) { acc in
                    AnyView(ComponentNode(message: message, component: acc))
                }
            }
        case 10:
            if let text = component.content {
                RichText(raw: text, mentions: message.mentions)
            }
        case 11:
            if let url = component.mediaItems.first?.media.best {
                RemoteImage(url: url, contentMode: .fill) { Theme.input }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case 12:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(component.mediaItems.enumerated()), id: \.offset) { _, item in
                    if let url = item.media.best {
                        let w = MediaMetrics.width
                        RemoteImage(url: url, contentMode: .fill) { Theme.input }
                            .frame(width: w, height: w * 0.62)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        case 13:
            if let s = component.fileURL, let url = URL(string: s) {
                Link(destination: url) {
                    Label("Файл", systemImage: "doc.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.link)
                }
            }
        case 14:
            if component.divider {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.vertical, 4)
            } else {
                Color.clear.frame(height: 8)
            }
        case 17:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(component.children) { child in
                    AnyView(ComponentNode(message: message, component: child))
                }
            }
            .padding(10)
            .padding(.leading, 4)
            .frame(maxWidth: MediaMetrics.width + 20, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(component.accent_color.map { Color(hex: UInt32($0)) } ?? Color(hex: 0x1E1F22))
                    .frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        default:
            EmptyView()
        }
    }
}

struct ComponentButton: View {
    @EnvironmentObject var store: Store
    let message: Message
    let component: Component
    @State private var busy = false

    private var color: Color {
        switch component.style {
        case 1: return Theme.blurple
        case 3: return Color(hex: 0x248046)
        case 4: return Color(hex: 0xDA373C)
        default: return Color(hex: 0x4E5058)
        }
    }

    var body: some View {
        Button {
            press()
        } label: {
            HStack(spacing: 6) {
                if let e = component.emoji {
                    EmojiView(emoji: e, size: 16)
                }
                if let l = component.label, !l.isEmpty {
                    Text(l)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                if component.style == 5 {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                if busy {
                    ProgressView().tint(.white).scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
            .opacity(component.disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(component.disabled || busy)
    }

    private func press() {
        if component.style == 5, let s = component.url, let url = URL(string: s) {
            UIApplication.shared.open(url)
            return
        }
        guard let cid = component.custom_id else { return }
        busy = true
        Task {
            await store.pressButton(message, customId: cid)
            busy = false
        }
    }
}

struct ComponentSelect: View {
    @EnvironmentObject var store: Store
    let message: Message
    let component: Component
    @State private var picked: SelectOption?

    private var titleText: String {
        if let p = picked { return p.label }
        if let d = component.options.first(where: { $0.isDefault == true }) { return d.label }
        return component.placeholder ?? "Выберите…"
    }

    var body: some View {
        Menu {
            ForEach(component.options) { o in
                Button(o.label) { pick(o) }
            }
        } label: {
            HStack {
                Text(titleText)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11))
            }
            .padding(10)
            .frame(maxWidth: MediaMetrics.width)
            .foregroundStyle(Theme.text)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 6))
        }
        .disabled(component.disabled)
    }

    private func pick(_ option: SelectOption) {
        picked = option
        guard let cid = component.custom_id else { return }
        Task { await store.selectOption(message, customId: cid, values: [option.value]) }
    }
}

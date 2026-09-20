import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PendingFile: Identifiable {
    let id = UUID()
    let file: UploadFile
    let thumb: UIImage?
}

struct ViewerItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ChatView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var translator: Translator
    let channel: Channel

    @State private var text = ""
    @State private var pending: [PendingFile] = []
    @State private var replyTo: Message?
    @State private var showAttachMenu = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showEmoji = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sending = false
    @State private var viewer: ViewerItem?
    @State private var actionMessage: Message?
    @State private var profileUser: User?
    @StateObject private var recorder = VoiceRecorder()
    @State private var showTranslate = false

    private var guildId: String? { store.guildID(of: channel) }

    private var tset: ChannelTranslateSettings {
        translator.settings[channel.id] ?? ChannelTranslateSettings()
    }

    private struct TranslateKey: Equatable {
        let enabled: Bool
        let count: Int
        let target: String
        let last: String?
        let total: Int
        let sheet: Bool
    }

    private var translateKey: TranslateKey {
        let msgs = store.messages[channel.id] ?? []
        let s = tset
        return TranslateKey(
            enabled: s.incomingEnabled,
            count: s.count,
            target: s.incomingTarget,
            last: msgs.last?.id,
            total: msgs.count,
            sheet: showTranslate
        )
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty
    }

    var body: some View {
        let msgs = store.messages[channel.id] ?? []
        withAttachments(chatCore(msgs))
            .sheet(item: $actionMessage) { m in actionSheet(m) }
            .sheet(item: $profileUser) { u in
                UserProfileSheet(user: u, guildId: guildId)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showEmoji) { emojiSheet }
            .sheet(isPresented: $showTranslate) {
                TranslateSettingsSheet(channelId: channel.id)
                    .environmentObject(translator)
            }
            .task(id: translateKey) { await runIncomingTranslation() }
            .fullScreenCover(item: $viewer) { item in viewerCover(item) }
            .task { await poll() }
            .onAppear { store.lastChannel = channel }
            .onDisappear { recorder.cancel() }
    }

    // MARK: - Каркас

    private func chatCore(_ msgs: [Message]) -> some View {
        VStack(spacing: 0) {
            messageList(msgs)
            if let r = replyTo { replyBar(r) }
            if !pending.isEmpty { pendingStrip }
            if recorder.isRecording { recordingBar } else { inputBar }
        }
        .background(Theme.chat)
        .simultaneousGesture(backSwipe)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.chat, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: channel.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Text(channel.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Свайп вправо из любого места чата возвращает к списку каналов.
    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { v in
                if v.translation.width > 90, abs(v.translation.height) < 70 {
                    dismiss()
                }
            }
    }

    private func withAttachments<V: View>(_ content: V) -> some View {
        content
            .confirmationDialog("Прикрепить", isPresented: $showAttachMenu, titleVisibility: .hidden) {
                Button("Фото и видео") { showPhotos = true }
                Button("Файл") { showFiles = true }
                Button("Отмена", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $showPhotos,
                selection: $photoItems,
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                importFiles(result)
            }
    }

    private func poll() async {
        await store.loadMessages(channel.id)
        // Запасное обновление на случай, если Gateway не доставил сообщение.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await store.loadMessages(channel.id, silent: true)
        }
    }

    // MARK: - Листы

    private func actionSheet(_ m: Message) -> some View {
        MessageActionSheet(
            message: m,
            channel: channel,
            guildId: guildId,
            onReply: { replyTo = m }
        )
        .environmentObject(store)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
    }

    private var emojiSheet: some View {
        EmojiPickerView(guildId: guildId) { ref in
            text += ref.inlineText
        }
        .environmentObject(store)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
    }

    private func viewerCover(_ item: ViewerItem) -> some View {
        ImageViewer(url: item.url) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { viewer = nil }
        }
        .presentationBackground(.clear)
    }

    // MARK: - Список сообщений

    private func runIncomingTranslation() async {
        let s = tset
        guard s.incomingEnabled, !showTranslate else { return }
        let window = Array((store.messages[channel.id] ?? []).suffix(s.count))
        await translator.translateIncoming(window, target: s.incomingTarget)
    }

    private func messageList(_ msgs: [Message]) -> some View {
        let s = tset
        let shown: Set<String> = s.incomingEnabled ? Set(msgs.suffix(s.count).map { $0.id }) : []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                        let header = needsHeader(i, msgs)
                        MessageRow(
                            message: m,
                            showHeader: header,
                            translation: shown.contains(m.id)
                                ? translator.incoming[translator.cacheKey(m, s.incomingTarget)]
                                : nil,
                            onImage: { url in viewer = ViewerItem(url: url) },
                            onProfile: { u in profileUser = u },
                            onReply: { replyTo = m },
                            onMenu: { actionMessage = m },
                            onReact: { ref in Task { await store.toggleReaction(ref, on: m) } }
                        )
                        .padding(.top, header ? 14 : 2)
                        .id(m.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: msgs.last?.id) { _, newValue in
                if let newValue { proxy.scrollTo(newValue, anchor: .bottom) }
            }
        }
    }

    private func needsHeader(_ i: Int, _ msgs: [Message]) -> Bool {
        guard i > 0 else { return true }
        let prev = msgs[i - 1]
        let cur = msgs[i]
        if cur.reply != nil || cur.forwarded != nil { return true }
        if prev.author.id != cur.author.id { return true }
        guard let a = prev.date, let b = cur.date else { return true }
        return b.timeIntervalSince(a) > 7 * 60
    }

    // MARK: - Ответ и вложения перед отправкой

    private func replyBar(_ r: Message) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Text("Ответ для")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Text(r.author.displayName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                replyTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var pendingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(pending) { p in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let t = p.thumb {
                                Image(uiImage: t).resizable().scaledToFill()
                            } else {
                                ZStack {
                                    Theme.input
                                    VStack(spacing: 4) {
                                        Image(systemName: "doc.fill")
                                        Text(p.file.name)
                                            .font(.system(size: 9))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .foregroundStyle(Theme.normalText)
                                    .padding(4)
                                }
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            pending.removeAll { $0.id == p.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Theme.panel)
    }

    // MARK: - Поле ввода

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                showAttachMenu = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.normalText)
                    .frame(width: 40, height: 40)
                    .background(Theme.input, in: Circle())
            }

            HStack(alignment: .bottom, spacing: 6) {
                TextField(
                    "",
                    text: $text,
                    prompt: Text("Написать в \(channel.title)").foregroundColor(Theme.muted),
                    axis: .vertical
                )
                .lineLimit(1...5)
                .foregroundStyle(Theme.text)
                .padding(.vertical, 10)
                .padding(.leading, 14)

                Button {
                    showTranslate = true
                } label: {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 20))
                        .foregroundStyle(tset.incomingEnabled || tset.outgoingEnabled ? Theme.blurple : Theme.muted)
                        .frame(width: 32, height: 40)
                }

                Button {
                    showEmoji = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 40)
                }

                if canSend {
                    Button(action: submit) {
                        Group {
                            if sending {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.blurple, in: Circle())
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                    .disabled(sending)
                } else {
                    Button(action: startRecording) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 40, height: 40)
                    }
                }
            }
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 20))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.chat)
    }

    // MARK: - Голосовое сообщение

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.red)
                    .frame(width: 40, height: 40)
                    .background(Theme.input, in: Circle())
            }
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text(durationText(recorder.elapsed))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.text)
                LiveWaveform(levels: recorder.levels)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.input, in: Capsule())
            Button(action: sendVoice) {
                Group {
                    if sending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Theme.blurple, in: Circle())
            }
            .disabled(sending)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.chat)
    }

    private func durationText(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func startRecording() {
        Task {
            let ok = await recorder.start()
            if !ok {
                store.error = "Нет доступа к микрофону. Разреши его в Настройки → DiscClient → Микрофон."
            }
        }
    }

    private func sendVoice() {
        guard !sending, let rec = recorder.stop() else { return }
        if rec.duration < 0.6 {
            try? FileManager.default.removeItem(at: rec.url)
            return
        }
        sending = true
        let replyId = replyTo?.id
        Task {
            let ok = await store.sendVoice(rec, to: channel.id, replyTo: replyId)
            sending = false
            if ok { replyTo = nil }
        }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !pending.isEmpty, !sending else { return }
        sending = true
        let files = pending.map { $0.file }
        let replyId = replyTo?.id
        let s = tset
        Task {
            var outText = t
            if s.outgoingEnabled, !t.isEmpty {
                if let translated = await translator.translateOutgoing(t, to: s.outgoingLang) {
                    outText = translated
                } else {
                    sending = false
                    store.error = "Не удалось перевести сообщение. Проверь, что языковые пакеты скачаны (Настройки → Приложения → Перевод), или выключи перевод моих сообщений."
                    return
                }
            }
            let ok = await store.send(outText, files: files, to: channel.id, replyTo: replyId)
            sending = false
            if ok {
                text = ""
                pending = []
                replyTo = nil
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let thumb = mime.hasPrefix("image/") ? UIImage(data: data) : nil
            pending.append(PendingFile(
                file: UploadFile(name: url.lastPathComponent, mime: mime, data: data),
                thumb: thumb
            ))
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for (n, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            var payload = data
            var ext = type?.preferredFilenameExtension ?? "jpg"
            var mime = type?.preferredMIMEType ?? "application/octet-stream"

            // HEIC и прочие форматы, которые Discord плохо показывает, переводим в JPEG.
            if let t = type,
               t.conforms(to: .image),
               !(t.conforms(to: .png) || t.conforms(to: .jpeg) || t.conforms(to: .gif) || t == .webP),
               let ui = UIImage(data: data),
               let jpg = ui.jpegData(compressionQuality: 0.9) {
                payload = jpg
                ext = "jpg"
                mime = "image/jpeg"
            }

            let name = "media_\(Int(Date().timeIntervalSince1970))_\(n).\(ext)"
            let thumb = mime.hasPrefix("image/") ? UIImage(data: payload) : nil
            pending.append(PendingFile(
                file: UploadFile(name: name, mime: mime, data: payload),
                thumb: thumb
            ))
        }
        photoItems = []
    }
}

// MARK: - Сообщение

struct MessageRow: View {
    let message: Message
    let showHeader: Bool
    let translation: TranslatedText?
    let onImage: (URL) -> Void
    let onProfile: (User) -> Void
    let onReply: () -> Void
    let onMenu: () -> Void
    let onReact: (EmojiRef) -> Void

    @State private var dragX: CGFloat = 0
    @State private var showOriginal = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(Theme.muted)
                .padding(.trailing, 22)
                .opacity(min(1, Double(-dragX) / 50))
                .scaleEffect(min(1, 0.6 + Double(-dragX) / 100))
            content
                .offset(x: dragX)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(replySwipe)
        .onLongPressGesture(minimumDuration: 0.4) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onMenu()
        }
    }

    /// Свайп сообщения влево = ответить.
    private var replySwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                if abs(v.translation.width) > abs(v.translation.height) * 1.5, v.translation.width < 0 {
                    dragX = max(-90, v.translation.width)
                } else if dragX != 0 && v.translation.width >= 0 {
                    dragX = 0
                }
            }
            .onEnded { _ in
                let trigger = dragX <= -60
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    dragX = 0
                }
                if trigger {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReply()
                }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let r = message.reply, showHeader {
                replyLine(r)
            }
            HStack(alignment: .top, spacing: 12) {
                if showHeader {
                    AvatarView(user: message.author, size: 40)
                        .onTapGesture { onProfile(message.author) }
                } else {
                    Color.clear.frame(width: 40, height: 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if showHeader { header }
                    if let tr = translation, !showOriginal {
                        RichText(raw: tr.text, mentions: message.mentions)
                    } else if !message.content.isEmpty {
                        RichText(raw: message.content, mentions: message.mentions)
                    }
                    if let tr = translation {
                        Button {
                            showOriginal.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "character.bubble")
                                    .font(.system(size: 10))
                                Text(showOriginal
                                     ? "показать перевод"
                                     : "переведено с \(Languages.name(tr.sourceCode).lowercased()) · оригинал")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    if let f = message.forwarded { forwardedBlock(f) }
                    ForEach(message.attachments) { a in
                        AttachmentView(attachment: a, onImage: onImage)
                    }
                    if !message.reactions.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(message.reactions) { r in
                                ReactionChip(reaction: r) { onReact(r.emoji) }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(message.author.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .onTapGesture { onProfile(message.author) }
            if message.author.bot == true {
                Text("APP")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.blurple, in: RoundedRectangle(cornerRadius: 4))
            }
            Text(message.timeText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
    }

    private func replyLine(_ r: ReplyRef) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.up.left")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            AvatarView(user: r.author, size: 16)
            Text("@" + r.author.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.normalText)
            Text(r.content.isEmpty ? "Вложение" : r.content.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.leading, 14)
    }

    private func forwardedBlock(_ f: ForwardedContent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                Text("Переслано")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            if !f.content.isEmpty {
                RichText(raw: f.content, mentions: [])
            }
            ForEach(f.attachments) { a in
                AttachmentView(attachment: a, onImage: onImage)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.muted.opacity(0.6))
                .frame(width: 3)
        }
    }
}

// MARK: - Вложение в сообщении

struct AttachmentView: View {
    let attachment: Attachment
    let onImage: (URL) -> Void

    private var fitted: CGSize {
        let w = CGFloat(attachment.width ?? 300)
        let h = CGFloat(attachment.height ?? 200)
        guard w > 0, h > 0 else { return CGSize(width: 260, height: 180) }
        let scale = min(1, 260 / w, 320 / h)
        return CGSize(width: w * scale, height: h * scale)
    }

    var body: some View {
        if attachment.isVoice {
            VoiceMessageView(attachment: attachment)
        } else if attachment.isImage, let url = URL(string: attachment.url) {
            RemoteImage(url: url, contentMode: .fill) {
                Theme.input
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { onImage(url) }
        } else if let url = URL(string: attachment.url) {
            Link(destination: url) {
                HStack(spacing: 10) {
                    Image(systemName: attachment.isVideo ? "play.rectangle.fill" : "doc.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.link)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.link)
                            .lineLimit(1)
                        Text(attachment.sizeText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: 280, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rail, lineWidth: 1))
            }
        }
    }
}

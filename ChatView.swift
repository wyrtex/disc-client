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
    @State private var scrollTarget: String?
    @State private var scrollAnchor: UnitPoint = .bottom
    @State private var flashId: String?
    @State private var mentionMap: [String: String] = [:]
    @State private var suggestions: [Suggestion] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var editing: Message?
    @State private var videoItem: ViewerItem?

    private struct Suggestion: Identifiable {
        let id: String
        let display: String
        let token: String
        let title: String
        let subtitle: String?
        let user: User?
        let icon: String?
    }

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
        let pending: Int
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
            sheet: showTranslate,
            pending: translator.pending.count
        )
    }

    private var canWrite: Bool { store.canSend(in: channel) }

    /// Если для перевода не хватает языкового пакета, предлагаем скачать его (сами ничего не запрашиваем).
    @ViewBuilder
    private var translateBanner: some View {
        let s = tset
        if s.incomingEnabled, let p = translator.pending.first(where: { $0.target == s.incomingTarget }) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.link)
                Text("Для перевода нужен языковой пакет: \(Languages.name(p.source)) → \(Languages.name(p.target))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Скачать") {
                    Task { await translator.prepare(p) }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.blurple, in: Capsule())
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.panel)
        }
    }

    private var authorsKey: Int {
        var set = Set<String>()
        for m in (store.messages[channel.id] ?? []).suffix(100) { set.insert(m.author.id) }
        return set.count
    }

    private func requestVisibleMembers() {
        guard let gid = guildId else { return }
        var ids = Set<String>()
        for m in (store.messages[channel.id] ?? []).suffix(100) { ids.insert(m.author.id) }
        store.requestMembers(guildId: gid, userIds: Array(ids))
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
            .fullScreenCover(item: $videoItem) { item in
                VideoViewer(url: item.url) { videoItem = nil }
                    .environmentObject(store)
            }
            .task { await poll() }
            .task {
                if let gid = guildId { await store.loadRoles(gid) }
            }
            .task(id: authorsKey) { requestVisibleMembers() }
            .onChange(of: text) { _, _ in updateSuggestions() }
            .onAppear { store.lastChannel = channel }
            .onDisappear { recorder.cancel() }
    }

    // MARK: - Каркас

    private func chatCore(_ msgs: [Message]) -> some View {
        VStack(spacing: 0) {
            translateBanner
            messageList(msgs)
            if !suggestions.isEmpty { suggestionList }
            if let e = editing { editBar(e) }
            if let r = replyTo { replyBar(r) }
            if !pending.isEmpty { pendingStrip }
            if recorder.isRecording {
                recordingBar
            } else if canWrite {
                inputBar
            } else {
                noWriteBar
            }
        }
        .background(Theme.chat)
        .environment(\.currentGuildId, guildId)
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
            onReply: { replyTo = m },
            onEdit: { startEdit(m) },
            onDelete: { Task { _ = await store.delete(m) } }
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
        let detached = store.detachedChannels.contains(channel.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topSentinel
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                        let header = needsHeader(i, msgs)
                        MessageRow(
                            message: m,
                            showHeader: header,
                            translation: shown.contains(m.id)
                                ? translator.incoming[translator.cacheKey(m, s.incomingTarget)]
                                : nil,
                            isMentioned: isMentioned(m),
                            flash: flashId == m.id,
                            authorName: store.guildNick(guildId: guildId, user: m.author, fallbackNick: m.member_nick),
                            authorColor: store.roleColor(guildId: guildId, userId: m.author.id, fallbackRoles: m.member_roles),
                            onImage: { url in viewer = ViewerItem(url: url) },
                            onVideo: { url in videoItem = ViewerItem(url: url) },
                            onProfile: { u in profileUser = u },
                            onReply: { replyTo = m },
                            onMenu: { actionMessage = m },
                            onReact: { ref in Task { await store.toggleReaction(ref, on: m) } },
                            onJump: { id in jump(to: id) }
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
                if let newValue, !detached { proxy.scrollTo(newValue, anchor: .bottom) }
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: scrollAnchor)
                scrollTarget = nil
            }
            .overlay(alignment: .bottomTrailing) {
                if detached {
                    Button {
                        Task { await store.returnToLatest(channel.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                            Text("К последним")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.blurple, in: Capsule())
                    }
                    .padding(12)
                }
            }
        }
    }

    /// Верх списка: когда он появляется на экране, подгружаем более старые сообщения.
    private var topSentinel: some View {
        Group {
            if store.loadingOlder.contains(channel.id) {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            } else if store.reachedTop.contains(channel.id) {
                Text("Это начало канала")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .onAppear { loadOlder() }
    }

    private func loadOlder() {
        Task {
            guard let anchor = await store.loadOlder(channel.id) else { return }
            scrollAnchor = .top
            scrollTarget = anchor
        }
    }

    /// Тап по «ответу»: переходим к исходному сообщению (если его нет в загруженных, подгружаем окно вокруг него).
    private func jump(to id: String) {
        let msgs = store.messages[channel.id] ?? []
        if msgs.contains(where: { $0.id == id }) {
            scrollAnchor = .center
            scrollTarget = id
            flash(id)
        } else {
            Task {
                if await store.loadAround(channel.id, messageId: id) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    scrollAnchor = .center
                    scrollTarget = id
                    flash(id)
                }
            }
        }
    }

    private func flash(_ id: String) {
        flashId = id
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if flashId == id { flashId = nil }
        }
    }

    private func isMentioned(_ m: Message) -> Bool {
        guard let me = store.me, m.author.id != me.id else { return false }
        if m.mention_everyone { return true }
        if m.mentions.contains(where: { $0.id == me.id }) { return true }
        if let gid = guildId, let roles = store.memberRoles[gid], !roles.isDisjoint(with: m.mention_roles) {
            return true
        }
        return false
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

    private var noWriteBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text("У вас нет разрешения отправлять сообщения в этом канале")
                .multilineTextAlignment(.leading)
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Theme.input.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.chat)
    }

    private func startEdit(_ m: Message) {
        replyTo = nil
        pending = []
        editing = m
        text = m.content
    }

    private func editBar(_ m: Message) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Text("Редактирование сообщения")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                editing = nil
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

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
        let t0 = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = resolveMentions(t0)
        if let e = editing {
            guard !t.isEmpty, !sending else { return }
            sending = true
            Task {
                let ok = await store.edit(e, content: t)
                sending = false
                if ok {
                    editing = nil
                    text = ""
                    mentionMap = [:]
                    suggestions = []
                }
            }
            return
        }
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
                mentionMap = [:]
                suggestions = []
            }
        }
    }

    // MARK: - Подсказки при вводе @ и #

    private func resolveMentions(_ s: String) -> String {
        var out = s
        for (display, token) in mentionMap.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: display, with: token)
        }
        return out
    }

    private func currentTrigger() -> (char: Character, query: String, range: Range<String.Index>)? {
        guard let idx = text.lastIndex(where: { $0 == "@" || $0 == "#" }) else { return nil }
        if idx != text.startIndex {
            let before = text[text.index(before: idx)]
            if !before.isWhitespace { return nil }
        }
        let query = String(text[text.index(after: idx)...])
        if query.contains(where: { $0.isWhitespace }) || query.count > 32 { return nil }
        return (text[idx], query, idx..<text.endIndex)
    }

    private func updateSuggestions() {
        suggestionTask?.cancel()
        guard let trig = currentTrigger() else {
            suggestions = []
            return
        }
        let q = trig.query.lowercased()

        if trig.char == "#" {
            suggestions = channelSuggestions(q)
            return
        }

        var list = memberSuggestions(q) + roleSuggestions(q)
        for special in ["everyone", "here"] where q.isEmpty || special.hasPrefix(q) {
            list.append(Suggestion(
                id: "special-\(special)",
                display: "@\(special)",
                token: "@\(special)",
                title: "@\(special)",
                subtitle: "Упомянуть всех",
                user: nil,
                icon: "megaphone.fill"
            ))
        }
        suggestions = Array(list.prefix(8))

        if let gid = guildId, !q.isEmpty {
            suggestionTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let remote = await store.searchMembers(guildId: gid, query: q)
                if Task.isCancelled { return }
                var current = suggestions
                for u in remote where !current.contains(where: { $0.id == "u-\(u.id)" }) {
                    current.append(userSuggestion(u))
                }
                suggestions = Array(current.prefix(8))
            }
        }
    }

    private func userSuggestion(_ u: User) -> Suggestion {
        Suggestion(
            id: "u-\(u.id)",
            display: "@" + u.displayName,
            token: "<@\(u.id)>",
            title: u.displayName,
            subtitle: u.username,
            user: u,
            icon: nil
        )
    }

    private func memberSuggestions(_ q: String) -> [Suggestion] {
        var users: [String: User] = [:]
        for m in store.messages[channel.id] ?? [] {
            users[m.author.id] = m.author
            for u in m.mentions { users[u.id] = u }
        }
        for u in channel.recipients ?? [] { users[u.id] = u }
        let matched = users.values
            .filter { q.isEmpty || $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q) }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        return matched.map { userSuggestion($0) }
    }

    private func roleSuggestions(_ q: String) -> [Suggestion] {
        guard let gid = guildId, let roles = store.guildRoles[gid] else { return [] }
        let matched = roles.filter { $0.id != gid && (q.isEmpty || $0.name.lowercased().contains(q)) }
        return matched.prefix(4).map { r in
            Suggestion(
                id: "r-\(r.id)",
                display: "@" + r.name,
                token: "<@&\(r.id)>",
                title: r.name,
                subtitle: "Роль",
                user: nil,
                icon: "person.2.fill"
            )
        }
    }

    private func channelSuggestions(_ q: String) -> [Suggestion] {
        guard let gid = guildId, let list = store.guildChannels[gid] else { return [] }
        let allowed: Set<Int> = [0, 2, 5, 13, 15]
        let matched = list.filter { ch in
            !ch.isCategory && allowed.contains(ch.type) && (q.isEmpty || (ch.name ?? "").lowercased().contains(q))
        }
        return matched.prefix(8).map { ch in
            let locked = store.isLocked(ch, guildId: gid)
            return Suggestion(
                id: "c-\(ch.id)",
                display: "#" + (ch.name ?? "канал"),
                token: "<#\(ch.id)>",
                title: ch.name ?? "канал",
                subtitle: locked ? "Нет доступа" : nil,
                user: nil,
                icon: locked ? "lock.fill" : ch.icon
            )
        }
    }

    private func applySuggestion(_ sg: Suggestion) {
        guard let trig = currentTrigger() else { return }
        text.replaceSubrange(trig.range, with: sg.display + " ")
        if sg.token != sg.display { mentionMap[sg.display] = sg.token }
        suggestions = []
    }

    private var suggestionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(suggestions) { sg in
                    Button {
                        applySuggestion(sg)
                    } label: {
                        HStack(spacing: 10) {
                            if let u = sg.user {
                                AvatarView(user: u, size: 28)
                            } else {
                                Image(systemName: sg.icon ?? "number")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: 28, height: 28)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sg.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if let sub = sg.subtitle {
                                    Text(sub)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 250)
        .background(Theme.panel)
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
    let isMentioned: Bool
    let flash: Bool
    let authorName: String
    let authorColor: Color?
    let onImage: (URL) -> Void
    let onVideo: (URL) -> Void
    let onProfile: (User) -> Void
    let onReply: () -> Void
    let onMenu: () -> Void
    let onReact: (EmojiRef) -> Void
    let onJump: (String) -> Void

    @State private var dragX: CGFloat = 0

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
        .background(rowBackground)
        .overlay {
            if isMentioned {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(hex: 0xF0B232), lineWidth: 1.5)
            }
        }
        .padding(.horizontal, 3)
        .animation(.easeOut(duration: 0.3), value: flash)
        .contentShape(Rectangle())
        .simultaneousGesture(replySwipe)
        .onLongPressGesture(minimumDuration: 0.4) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onMenu()
        }
    }

    /// Если сообщение состоит только из ссылки на гифку или картинку, ссылку прячем (как в Discord).
    private var hideText: Bool {
        let t = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("http"), !t.contains(" "), !t.contains("\n") else { return false }
        return message.embeds.contains { e in
            let type = e.type ?? ""
            return (type == "gifv" || type == "image") && e.url == t
        }
    }

    private var rowBackground: Color {
        if flash { return Theme.blurple.opacity(0.28) }
        if isMentioned { return Color(hex: 0xF0B232).opacity(0.10) }
        return Color.clear
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
                    if let tr = translation {
                        RichText(raw: tr.text, mentions: message.mentions)
                    } else if !message.content.isEmpty && !hideText {
                        RichText(raw: message.content, mentions: message.mentions)
                    }
                    if message.edited && translation == nil {
                        Text("(изменено)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                    if let f = message.forwarded { forwardedBlock(f) }
                    MessageMedia(message: message, onImage: onImage, onVideo: onVideo)
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
            Text(authorName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(authorColor ?? Color.white)
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
        .contentShape(Rectangle())
        .onTapGesture { onJump(r.id) }
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

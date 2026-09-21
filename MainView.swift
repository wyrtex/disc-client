import SwiftUI
import Translation
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var translator: Translator
    @State private var selection: String? = nil   // nil = личные сообщения
    @State private var collapsed: Set<String> = []
    @State private var confirmLogout = false
    @State private var showVoice = false

    var body: some View {
        NavigationStack(path: $store.path) {
            ZStack {
                Theme.rail.ignoresSafeArea()
                HStack(spacing: 0) {
                    ServerRail(selection: $selection)
                    ChannelPanel(
                        selection: selection,
                        collapsed: $collapsed,
                        onUserTap: { confirmLogout = true },
                        onOpenVoice: { showVoice = true }
                    )
                }
            }
            .navigationDestination(for: Channel.self) { ch in
                if ch.type == 15 {
                    ForumView(channel: ch)
                } else {
                    ChatView(channel: ch)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .translationTask(translator.configuration) { session in
            await translator.run(session)
        }
        .fullScreenCover(isPresented: $showVoice) {
            VoiceView(voice: store.voice) { showVoice = false }
                .environmentObject(store)
        }
        .confirmationDialog("Аккаунт", isPresented: $confirmLogout, titleVisibility: .hidden) {
            Button("Выйти из аккаунта", role: .destructive) { store.logout() }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Ошибка", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.error ?? "")
        }
    }
}

// MARK: - Левая колонка с серверами

struct RailItem<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    let content: Content

    init(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.action = action
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white)
                .frame(width: 4, height: selected ? 40 : 0)
                .animation(.easeOut(duration: 0.15), value: selected)
            Button(action: action) {
                content.frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 48)
    }
}

/// Перетаскивание сервера в левой колонке: зажми иконку и веди на новое место.
struct GuildDropDelegate: DropDelegate {
    let target: Guild
    let move: (String, String) -> Void
    let finish: () -> Void
    @Binding var dragging: Guild?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target.id else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            move(dragging.id, target.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        finish()
        return true
    }
}

struct ServerRail: View {
    @EnvironmentObject var store: Store
    @Binding var selection: String?
    @State private var dragging: Guild?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                RailItem(selected: selection == nil, action: { selection = nil }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: selection == nil ? 16 : 24)
                            .fill(selection == nil ? Theme.blurple : Theme.chat)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(.white)
                    }
                    .animation(.easeOut(duration: 0.15), value: selection)
                }
                Rectangle()
                    .fill(Theme.chat)
                    .frame(width: 32, height: 2)
                ForEach(store.guilds) { g in
                    RailItem(selected: selection == g.id, action: { selection = g.id }) {
                        GuildIcon(guild: g, selected: selection == g.id)
                            .overlay(alignment: .bottomTrailing) {
                                GuildVoiceBadge(state: store.guildVoiceSummary(g.id))
                                    .offset(x: 5, y: 5)
                            }
                    }
                    .opacity(dragging?.id == g.id ? 0.4 : 1)
                    .onDrag {
                        dragging = g
                        return NSItemProvider(object: g.id as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: GuildDropDelegate(
                        target: g,
                        move: { from, to in store.moveGuild(from, to: to) },
                        finish: { store.saveGuildOrder() },
                        dragging: $dragging
                    ))
                }
            }
            .padding(.vertical, 10)
        }
        .frame(width: 72)
    }
}

// MARK: - Панель каналов / личных сообщений

struct ChannelPanel: View {
    @EnvironmentObject var store: Store
    let selection: String?
    @Binding var collapsed: Set<String>
    let onUserTap: () -> Void
    let onOpenVoice: () -> Void

    @State private var showServer = false

    private var guild: Guild? {
        store.guilds.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            if guild == nil { header }
            ScrollView {
                if let g = guild {
                    VStack(spacing: 0) {
                        guildHeader(g)
                        guildContent(g)
                    }
                } else {
                    dmContent
                }
            }
            VoiceBar(voice: store.voice, onOpen: onOpenVoice)
            UserBar(onTap: onUserTap)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        ))
        .ignoresSafeArea(edges: .bottom)
        .simultaneousGesture(openLastChatSwipe)
        .task(id: selection) {
            store.selectedGuildId = selection
            if let g = guild {
                store.resolveVoiceUsers(guildId: g.id)
                await store.loadGuildChannels(g)
                _ = await store.loadGuildDetail(g.id)
            }
        }
        .sheet(isPresented: $showServer) {
            if let g = guild {
                ServerProfileSheet(guild: g)
                    .environmentObject(store)
            }
        }

    }

    /// Свайп влево по списку каналов возвращает в последний открытый чат.
    private var openLastChatSwipe: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { v in
                if v.translation.width < -90,
                   abs(v.translation.height) < 70,
                   store.path.isEmpty,
                   let last = store.lastChannel {
                    store.path.append(last)
                }
            }
    }

    // MARK: Шапка сервера (баннер, название, статистика). Прокручивается вместе со списком.

    private func guildHeader(_ g: Guild) -> some View {
        let detail = store.guildDetails[g.id]
        let banner = detail?.bannerURL
        let height: CGFloat = banner == nil ? 76 : 150
        return Button {
            showServer = true
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let banner {
                    RemoteImage(url: banner) { Theme.panel }
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .clipped()
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: height)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(g.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.muted)
                    }
                    guildStats(detail)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .bottomLeading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func guildStats(_ detail: GuildDetail?) -> some View {
        if let d = detail, d.approximate_presence_count != nil || d.approximate_member_count != nil {
            HStack(spacing: 12) {
                if let online = d.approximate_presence_count {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.green).frame(width: 8, height: 8)
                        Text("\(online.formatted()) в сети")
                    }
                }
                if let total = d.approximate_member_count {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.muted).frame(width: 8, height: 8)
                        Text("\(total.formatted()) участников")
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text.opacity(0.85))
        }
    }

    // MARK: Шапка (личные сообщения)

    private var header: some View {
        Button {
            if guild != nil { showServer = true }
        } label: {
            headerLabel
        }
        .buttonStyle(.plain)
    }

    private var headerLabel: some View {
        let banner = guild.flatMap { store.guildDetails[$0.id]?.bannerURL }
        return ZStack(alignment: .bottomLeading) {
            if let banner {
                RemoteImage(url: banner) { Theme.panel }
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .clipped()
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110)
            }
            HStack(spacing: 6) {
                Text(guild?.name ?? "Сообщения")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if guild != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1)
        }
    }

    // MARK: Личные сообщения

    private var dmContent: some View {
        LazyVStack(spacing: 2) {
            ForEach(store.dms) { ch in
                NavigationLink(value: ch) {
                    HStack(spacing: 12) {
                        AvatarView(user: ch.recipients?.first, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(ch.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if let d = store.dmPreviews[ch.id]?.date {
                                    Text(shortTime(d))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.muted)
                                }
                            }
                            if let p = store.dmPreviews[ch.id] {
                                Text(store.previewText(p))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .task(id: ch.last_message_id) {
                    await store.loadDMPreview(ch)
                }
            }
        }
        .padding(.top, 8)
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd.MM"
        return f.string(from: d)
    }

    // MARK: Каналы сервера

    @ViewBuilder
    private func guildContent(_ g: Guild) -> some View {
        if let all = store.guildChannels[g.id] {
            let groups = ChannelGroup.build(all)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { grp in
                    let isOpen = grp.category.map { !collapsed.contains($0.id) } ?? true
                    if let cat = grp.category {
                        Button {
                            if collapsed.contains(cat.id) { collapsed.remove(cat.id) } else { collapsed.insert(cat.id) }
                        } label: {
                            categoryHeader(cat, open: isOpen)
                        }
                        .buttonStyle(.plain)
                    }
                    if isOpen {
                        ForEach(grp.channels) { ch in
                            channelRow(ch, guildId: g.id)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        } else {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func categoryHeader(_ cat: Channel, open: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
            Text(cat.title.uppercased())
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func channelRow(_ ch: Channel, guildId: String) -> some View {
        let locked = store.isLocked(ch, guildId: guildId)
        if locked {
            rowLabel(ch, locked: true).opacity(0.4)
        } else if ch.type == 0 || ch.type == 5 || ch.type == 15 {
            NavigationLink(value: ch) { rowLabel(ch, locked: false) }
                .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    store.voice.join(guildId: guildId, channel: ch)
                    onOpenVoice()
                } label: { rowLabel(ch, locked: false) }
                    .buttonStyle(.plain)
                ForEach(store.members(in: ch.id, guildId: guildId), id: \.userId) { m in
                    VoiceMemberRow(state: m)
                }
            }
        }
    }

    private func rowLabel(_ ch: Channel, locked: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: locked ? "lock.fill" : ch.icon)
                .font(.system(size: 15))
                .frame(width: 22)
            Text(ch.title)
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Нижняя плашка пользователя

struct UserBar: View {
    @EnvironmentObject var store: Store
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                AvatarView(user: store.me, size: 36)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Theme.green)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Theme.userBar, lineWidth: 2))
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.me?.displayName ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(store.me?.username ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(Theme.muted)
            }
            .padding(10)
            .background(Theme.userBar, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .buttonStyle(.plain)
    }
}


/// Значок на иконке сервера: LIVE (кто-то стримит), камера или просто люди в голосе.
struct GuildVoiceBadge: View {
    let state: GuildVoiceSummary

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .voice:
            badge(icon: "speaker.wave.2.fill", color: Theme.green)
        case .video:
            badge(icon: "video.fill", color: Theme.green)
        case .stream:
            Text("LIVE")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().stroke(Theme.rail, lineWidth: 2))
        }
    }

    private func badge(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color, in: Circle())
            .overlay(Circle().stroke(Theme.rail, lineWidth: 2))
    }
}

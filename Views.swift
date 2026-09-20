import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.me != nil {
                MainView()
            } else {
                LoginView()
            }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var store: Store
    @State private var token = ""
    @State private var showWeb = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Токен аккаунта") {
                    SecureField("Вставь токен", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Toggle("Использовать прокси", isOn: $store.proxy.enabled)
                    if store.proxy.enabled {
                        Picker("Тип", selection: $store.proxy.socks) {
                            Text("SOCKS5").tag(true)
                            Text("HTTP").tag(false)
                        }
                        TextField("Хост", text: $store.proxy.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Порт", value: $store.proxy.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("Прокси")
                } footer: {
                    Text("Пока встроенного туннеля нет: включи Happ на телефоне, а прокси оставь выключенным.")
                }
                if let error = store.error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button {
                        Task { await store.login(token: token) }
                    } label: {
                        if store.isLoading { ProgressView() } else { Text("Войти") }
                    }
                    .disabled(token.isEmpty || store.isLoading)
                }
            }
            .navigationTitle("DiscClient")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Через браузер") { showWeb = true }
                }
            }
            .sheet(isPresented: $showWeb) {
                WebLoginView { t in
                    showWeb = false
                    Task { await store.login(token: t) }
                }
                .ignoresSafeArea()
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
            List {
                Section("Личные сообщения") {
                    ForEach(store.dms) { ch in
                        NavigationLink(ch.title) { ChatView(channel: ch) }
                    }
                }
                Section("Серверы") {
                    ForEach(store.guilds) { g in
                        NavigationLink(g.name) { ChannelListView(guild: g) }
                    }
                }
            }
            .navigationTitle(store.me?.displayName ?? "Чаты")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Выйти", role: .destructive) { store.logout() }
                }
            }
        }
    }
}

struct ChannelListView: View {
    @EnvironmentObject var store: Store
    let guild: Guild
    @State private var channels: [Channel] = []
    @State private var loaded = false

    var body: some View {
        List(channels) { ch in
            NavigationLink("# " + ch.title) { ChatView(channel: ch) }
        }
        .overlay {
            if !loaded { ProgressView() }
        }
        .navigationTitle(guild.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            channels = await store.loadChannels(guildId: guild.id)
            loaded = true
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: Store
    let channel: Channel
    @State private var text = ""

    var body: some View {
        let msgs = store.messages[channel.id] ?? []
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(msgs) { m in
                            MessageRow(message: m).id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: msgs.last?.id) { _, newValue in
                    if let newValue { proxy.scrollTo(newValue, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Сообщение", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    text = ""
                    Task { await store.send(t, to: channel.id) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
            }
            .padding(8)
        }
        .navigationTitle(channel.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadMessages(channel.id)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await store.loadMessages(channel.id)
            }
        }
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.author.displayName).font(.subheadline.bold())
                Text(message.timeString).font(.caption2).foregroundStyle(.secondary)
            }
            if !message.content.isEmpty {
                Text(message.content).textSelection(.enabled)
            }
            ForEach(message.attachments) { a in
                if let url = URL(string: a.url) {
                    Link("📎 " + a.filename, destination: url).font(.footnote)
                }
            }
        }
    }
}

import SwiftUI
import AVKit

// MARK: - Экран голосового канала

struct VoiceView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var voice: VoiceSpike
    let onMinimize: () -> Void

    @State private var showAudio = false
    @State private var showLog = false

    var body: some View {
        ZStack {
            Theme.chat.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if voice.activeChannel == nil {
                    Spacer()
                    Text("Ты не подключён к голосовому каналу")
                        .foregroundStyle(Theme.muted)
                    Spacer()
                } else {
                    participants
                }
                if voice.captionsEnabled {
                    CaptionsPanel(voice: voice)
                }
                controls
            }
        }
        .sheet(isPresented: $showAudio) {
            AudioSettingsSheet(voice: voice)
        }
        .sheet(isPresented: $showLog) {
            VoiceLogView(voice: voice)
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40)
                    .background(Theme.input, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: voice.activeChannel?.icon ?? "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                    Text(voice.activeChannel?.title ?? "Голос")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if voice.encrypted {
                        Image(systemName: "lock.fill").font(.system(size: 10))
                    }
                    Text(voice.status).font(.system(size: 12))
                }
                .foregroundStyle(voice.encrypted ? Theme.green : Theme.muted)
            }
            Spacer()
            Button {
                showLog = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 40, height: 40)
                    .background(Theme.input, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Участники

    private var participants: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(voice.participantIds, id: \.self) { id in
                    ParticipantTile(voice: voice, id: id)
                }
            }
            .padding(16)
        }
    }

    // MARK: Кнопки управления

    private var controls: some View {
        HStack(spacing: 12) {
            controlButton(
                icon: (voice.muted || voice.deafened) ? "mic.slash.fill" : "mic.fill",
                active: voice.muted || voice.deafened
            ) { voice.toggleMute() }

            controlButton(
                icon: voice.deafened ? "speaker.slash.fill" : "headphones",
                active: voice.deafened
            ) { voice.toggleDeafen() }

            controlButton(icon: "captions.bubble.fill", active: voice.captionsEnabled) {
                voice.setCaptions(!voice.captionsEnabled)
            }

            controlButton(icon: voice.speakerOn ? "speaker.wave.3.fill" : "ear.fill", active: false) {
                showAudio = true
            }

            Button {
                voice.leave()
                onMinimize()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.red, in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
    }

    private func controlButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(active ? Color.black : Theme.text)
                .frame(width: 54, height: 54)
                .background(active ? Color.white : Theme.input, in: Circle())
        }
    }
}

// MARK: - Плитка участника

struct ParticipantTile: View {
    @ObservedObject var voice: VoiceSpike
    let id: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let speaking = ctx.date.timeIntervalSince(voice.lastHeard[id] ?? .distantPast) < 0.6
            let flag = voice.flags[id] ?? VoiceFlags()
            VStack(spacing: 8) {
                AvatarView(user: voice.users[id], size: 76)
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(speaking ? Theme.green : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if flag.stream { liveBadge }
                    if flag.video { badge("video.fill", color: Theme.green) }
                    if flag.deaf {
                        badge("speaker.slash.fill")
                    } else if flag.mute {
                        badge("mic.slash.fill")
                    }
                }
                .padding(8)
            }
        }
    }

    private var name: String {
        if let u = voice.users[id] { return u.displayName + (id == voice.userId ? " (ты)" : "") }
        return id == voice.userId ? "Ты" : "…"
    }

    private func badge(_ icon: String, color: Color = .red) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(Color.red, in: Capsule())
    }
}

// MARK: - Участник голосового канала в списке каналов

struct VoiceMemberRow: View {
    @EnvironmentObject var store: Store
    let state: VoiceMemberState

    var body: some View {
        let user = store.voiceUsers[state.userId]
        HStack(spacing: 8) {
            AvatarView(user: user, size: 22)
            Text(user?.displayName ?? "…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if state.stream {
                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
            }
            if state.video {
                Image(systemName: "video.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            if state.deaf {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            } else if state.mute {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.leading, 44)
        .padding(.trailing, 14)
        .padding(.vertical, 3)
    }
}

// MARK: - Субтитры

struct CaptionsPanel: View {
    @ObservedObject var voice: VoiceSpike

    private var langName: String {
        TranscriptLanguage.all.first(where: { $0.code == voice.captionLang })?.name ?? voice.captionLang
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(Theme.muted)
                Text("Субтитры")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Menu {
                    ForEach(TranscriptLanguage.all) { l in
                        Button(l.name) { voice.setCaptionLanguage(l.code) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(langName)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if !voice.captionStatus.isEmpty {
                Text(voice.captionStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(voice.captions) { c in
                            HStack(alignment: .top, spacing: 8) {
                                AvatarView(user: voice.users[c.userId], size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(voice.users[c.userId]?.displayName ?? (c.userId == voice.userId ? "Ты" : "…"))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.muted)
                                    Text(c.text)
                                        .font(.system(size: 15))
                                        .foregroundStyle(c.isFinal ? Theme.text : Theme.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .id(c.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .onChange(of: voice.captionsVersion) { _, _ in
                    if let last = voice.captions.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 210)
        .background(Theme.panel)
    }
}

// MARK: - Мини-панель «голос подключён»

struct VoiceBar: View {
    @ObservedObject var voice: VoiceSpike
    let onOpen: () -> Void

    var body: some View {
        if let ch = voice.activeChannel {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.encrypted ? "Голос подключён · E2EE" : voice.status)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(voice.encrypted ? Theme.green : Theme.muted)
                        .lineLimit(1)
                    Text(ch.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    voice.toggleMute()
                } label: {
                    Image(systemName: (voice.muted || voice.deafened) ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34)
                        .background(Theme.input, in: Circle())
                }
                Button {
                    voice.leave()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.red, in: Circle())
                }
            }
            .padding(10)
            .background(Theme.userBar, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
    }
}

// MARK: - Настройки звука

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(Theme.text)
        v.activeTintColor = UIColor(Theme.blurple)
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct AudioSettingsSheet: View {
    @ObservedObject var voice: VoiceSpike
    @State private var inputs: [VoiceAudio.InputDevice] = []
    @State private var outputName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Звук")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)

                card {
                    Text("Куда играет звук")
                        .font(.system(size: 15, weight: .semibold))
                    Picker("", selection: Binding(
                        get: { voice.speakerOn },
                        set: { voice.setSpeaker($0); refresh() }
                    )) {
                        Text("Динамик").tag(true)
                        Text("Телефон и наушники").tag(false)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Bluetooth и AirPlay")
                        Spacer()
                        RoutePickerView().frame(width: 36, height: 36)
                    }
                    Text("Сейчас: \(outputName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }

                card {
                    Text("Микрофон")
                        .font(.system(size: 15, weight: .semibold))
                    if inputs.isEmpty {
                        Text("Нет доступных микрофонов (доступ не выдан или голос не подключён)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(inputs) { input in
                        Button {
                            VoiceAudio.selectInput(uid: input.id)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { refresh() }
                        } label: {
                            HStack {
                                Text(input.name)
                                Spacer()
                                if input.selected {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.link)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                    HStack {
                        Text("Порог микрофона")
                        Spacer()
                        Text("\(Int(voice.vadThreshold)) дБ")
                            .foregroundStyle(Theme.muted)
                    }
                    Slider(value: $voice.vadThreshold, in: -70 ... -20, step: 1)
                        .tint(Theme.blurple)
                    ProgressView(value: max(0, min(1, (voice.micLevelDb + 80) / 80)))
                        .tint(voice.micLevelDb > voice.vadThreshold ? Theme.green : Theme.muted)
                    Text("Микрофон включается, когда уровень выше порога. Полоска показывает текущий уровень. Если тебя не слышат, сдвинь порог влево.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(16)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.panel)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
        .onAppear { refresh() }
    }

    private func refresh() {
        inputs = VoiceAudio.inputDevices()
        outputName = VoiceAudio.currentOutputName()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chat, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Журнал подключения

struct VoiceLogView: View {
    @ObservedObject var voice: VoiceSpike

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Журнал голоса")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    UIPasteboard.general.string = voice.log.joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 40, height: 40)
                        .background(Theme.input, in: Circle())
                        .foregroundStyle(Theme.text)
                }
            }

            Picker("DAVE", selection: $voice.daveVersion) {
                Text("DAVE 0 (без E2EE)").tag(0)
                Text("DAVE 1").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(voice.isConnected)

            Toggle("Видео (эксперимент, только лог)", isOn: $voice.videoProbe)
                .tint(Theme.blurple)
                .foregroundStyle(Theme.text)
                .disabled(voice.isConnected)

            Button {
                voice.add("DAVE в сборке: \(DaveLib.isBuiltIn ? "да" : "нет")")
                for line in DaveLib.selfTest() { voice.add(line) }
            } label: {
                Text("Проверить библиотеку DAVE")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.input, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Theme.text)
            }

            if !voice.gwLog.isEmpty {
                Text("Основной шлюз:\n" + voice.gwLog.suffix(3).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(voice.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.normalText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .background(Theme.rail, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: voice.log.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .padding(16)
        .background(Theme.panel)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
    }
}

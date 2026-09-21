import SwiftUI

/// Меню по долгому нажатию на сообщение: реакции, ответить, переслать, копировать.
struct MessageActionSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let message: Message
    let channel: Channel
    let guildId: String?
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    enum Mode { case menu, picker, forward }
    @State private var mode: Mode = .menu
    @State private var confirmDelete = false

    private let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .menu:
                menu
            case .picker:
                subHeader("Реакция")
                EmojiPickerView(guildId: guildId) { ref in
                    react(ref)
                }
            case .forward:
                subHeader("Переслать")
                ForwardList(message: message, source: channel) {
                    dismiss()
                }
            }
        }
        .confirmationDialog("Удалить сообщение?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                dismiss()
                onDelete()
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: Меню

    private var menu: some View {
        ScrollView {
            VStack(spacing: 12) {
                preview
                HStack(spacing: 6) {
                    ForEach(quick, id: \.self) { e in
                        Button {
                            react(EmojiRef(id: nil, name: e))
                        } label: {
                            Text(e)
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        mode = .picker
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                actionRow("arrowshape.turn.up.left.fill", "Ответить") {
                    dismiss()
                    onReply()
                }
                actionRow("arrowshape.turn.up.right.fill", "Переслать") {
                    mode = .forward
                }
                if !message.content.isEmpty {
                    actionRow("doc.on.doc.fill", "Копировать текст") {
                        UIPasteboard.general.string = message.content
                        dismiss()
                    }
                }
                if message.author.id == store.me?.id {
                    actionRow("pencil", "Редактировать") {
                        dismiss()
                        onEdit()
                    }
                    Button {
                        confirmDelete = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "trash.fill")
                                .frame(width: 24)
                            Text("Удалить")
                                .font(.system(size: 16, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(Color.red)
                        .padding(14)
                        .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private var preview: some View {
        HStack(spacing: 10) {
            AvatarView(user: message.author, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.author.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(message.content.isEmpty ? "Вложение" : message.content.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func actionRow(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.text)
            .padding(14)
            .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func subHeader(_ title: String) -> some View {
        HStack {
            Button {
                mode = .menu
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36)
            }
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
    }

    private func react(_ ref: EmojiRef) {
        let m = message
        Task { await store.toggleReaction(ref, on: m) }
        dismiss()
    }
}

// MARK: - Выбор чата для пересылки

struct ForwardList: View {
    @EnvironmentObject var store: Store
    let message: Message
    let source: Channel
    let onDone: () -> Void

    @State private var query = ""
    @State private var sendingTo: String?

    private func matches(_ s: String) -> Bool {
        query.isEmpty || s.localizedCaseInsensitiveContains(query)
    }

    private func textChannels(_ g: Guild) -> [Channel] {
        (store.guildChannels[g.id] ?? []).filter {
            ($0.type == 0 || $0.type == 5)
                && !store.isLocked($0, guildId: g.id)
                && matches($0.title)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("", text: $query, prompt: Text("Поиск").foregroundColor(Theme.muted))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.text)
                .padding(10)
                .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let dms = store.dms.filter { matches($0.title) }
                    if !dms.isEmpty {
                        sectionTitle("Личные сообщения")
                        ForEach(dms) { ch in
                            row(ch, title: ch.title, user: ch.recipients?.first)
                        }
                    }
                    ForEach(store.guilds) { g in
                        let chans = textChannels(g)
                        if !chans.isEmpty {
                            sectionTitle(g.name)
                            ForEach(chans) { ch in
                                row(ch, title: "# " + ch.title, user: nil)
                            }
                        }
                    }
                    Text("Каналы сервера появляются здесь после того, как ты открыл этот сервер в списке.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .padding(16)
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func row(_ ch: Channel, title: String, user: User?) -> some View {
        Button {
            guard sendingTo == nil else { return }
            sendingTo = ch.id
            Task {
                let ok = await store.forward(message, from: source, to: ch)
                sendingTo = nil
                if ok { onDone() }
            }
        } label: {
            HStack(spacing: 12) {
                if let user {
                    AvatarView(user: user, size: 32)
                } else {
                    Image(systemName: "number")
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32)
                }
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                if sendingTo == ch.id {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

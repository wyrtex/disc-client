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
    let channel: Channel

    @State private var text = ""
    @State private var pending: [PendingFile] = []
    @State private var showAttachMenu = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sending = false
    @State private var viewer: ViewerItem?

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty
    }

    var body: some View {
        let msgs = store.messages[channel.id] ?? []
        VStack(spacing: 0) {
            messageList(msgs)
            if !pending.isEmpty { pendingStrip }
            inputBar
        }
        .background(Theme.chat)
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
        .fullScreenCover(item: $viewer) { item in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                RemoteImage(url: item.url, contentMode: .fit) {
                    ProgressView().tint(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button {
                    viewer = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding()
            }
        }
        .task {
            await store.loadMessages(channel.id)
            // Запасное обновление на случай, если Gateway не доставил сообщение.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await store.loadMessages(channel.id, silent: true)
            }
        }
    }

    // MARK: - Список сообщений

    private func messageList(_ msgs: [Message]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                        let header = needsHeader(i, msgs)
                        MessageRow(message: m, showHeader: header) { url in
                            viewer = ViewerItem(url: url)
                        }
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
        if cur.reply != nil { return true }
        if prev.author.id != cur.author.id { return true }
        guard let a = prev.date, let b = cur.date else { return true }
        return b.timeIntervalSince(a) > 7 * 60
    }

    // MARK: - Вложения перед отправкой

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
                .padding(.trailing, canSend ? 0 : 14)

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
                    .padding(4)
                    .disabled(sending)
                }
            }
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 20))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.chat)
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !pending.isEmpty, !sending else { return }
        sending = true
        let files = pending.map { $0.file }
        Task {
            let ok = await store.send(t, files: files, to: channel.id)
            sending = false
            if ok {
                text = ""
                pending = []
            }
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
    let onImage: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let r = message.reply, showHeader {
                replyLine(r)
            }
            HStack(alignment: .top, spacing: 12) {
                if showHeader {
                    AvatarView(user: message.author, size: 40)
                } else {
                    Color.clear.frame(width: 40, height: 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if showHeader { header }
                    if !message.content.isEmpty {
                        Text(DiscordText.attributed(message.content, mentions: message.mentions))
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.normalText)
                            .tint(Theme.link)
                            .textSelection(.enabled)
                    }
                    ForEach(message.attachments) { a in
                        AttachmentView(attachment: a, onImage: onImage)
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
        if attachment.isImage, let url = URL(string: attachment.url) {
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

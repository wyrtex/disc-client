import SwiftUI

struct ForumView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let channel: Channel

    @State private var showNew = false
    @State private var loading = true

    var body: some View {
        let threads = store.forumThreads[channel.id] ?? []
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(threads) { t in
                    NavigationLink(value: t) {
                        ForumPostCard(thread: t, preview: store.forumPreviews[t.id])
                    }
                    .buttonStyle(.plain)
                }
                if store.forumHasMore[channel.id] == true {
                    Button("Загрузить ещё") {
                        Task { await store.loadForum(channel, more: true) }
                    }
                    .foregroundStyle(Theme.link)
                    .padding(.vertical, 8)
                }
                if threads.isEmpty && !loading {
                    Text("Пока нет постов")
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 40)
                }
            }
            .padding(12)
        }
        .overlay {
            if loading && threads.isEmpty {
                ProgressView().tint(.white)
            }
        }
        .background(Theme.chat)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.chat, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    Text(channel.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNew = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .simultaneousGesture(backSwipe)
        .sheet(isPresented: $showNew) {
            NewPostSheet(forum: channel)
                .environmentObject(store)
        }
        .task {
            await store.loadForum(channel)
            loading = false
        }
        .refreshable {
            await store.loadForum(channel)
        }
        .onAppear { store.lastChannel = channel }
    }

    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { v in
                if v.translation.width > 90, abs(v.translation.height) < 70 {
                    dismiss()
                }
            }
    }
}

struct ForumPostCard: View {
    let thread: Channel
    let preview: Message?

    private var imageURL: URL? {
        guard let a = preview?.attachments.first(where: { $0.isImage }) else { return nil }
        return URL(string: a.url)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(thread.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let p = preview, !p.content.isEmpty {
                    Text(p.content.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 8) {
                    if let a = preview?.author {
                        AvatarView(user: a, size: 18)
                        Text(a.displayName)
                            .lineLimit(1)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left")
                        Text("\(thread.message_count ?? 0)")
                    }
                    if let d = snowflakeDate(thread.last_message_id ?? thread.id) {
                        Text(relativeString(d))
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            if let url = imageURL {
                RemoteImage(url: url) { Theme.input }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NewPostSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let forum: Channel

    @State private var title = ""
    @State private var text = ""
    @State private var sending = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Отмена") { dismiss() }
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text("Новый пост")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    publish()
                } label: {
                    if sending { ProgressView().tint(.white) } else { Text("Создать").bold() }
                }
                .foregroundStyle(Theme.link)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                          || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || sending)
            }
            TextField("", text: $title, prompt: Text("Название").foregroundColor(Theme.muted))
                .foregroundStyle(Theme.text)
                .padding(12)
                .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
            TextField("", text: $text, prompt: Text("Текст поста").foregroundColor(Theme.muted), axis: .vertical)
                .lineLimit(5...12)
                .foregroundStyle(Theme.text)
                .padding(12)
                .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
        .padding(16)
        .background(Theme.panel)
        .presentationDetents([.large])
        .presentationBackground(Theme.panel)
    }

    private func publish() {
        sending = true
        let t = title.trimmingCharacters(in: .whitespaces)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ch = await store.createPost(in: forum, title: t, text: body)
            sending = false
            if let ch {
                dismiss()
                store.path.append(ch)
            }
        }
    }
}

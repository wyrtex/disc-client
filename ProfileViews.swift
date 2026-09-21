import SwiftUI

// MARK: - Профиль пользователя

struct UserProfileSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let user: User
    let guildId: String?
    @State private var profile: ProfileResponse?

    private var shown: User { profile?.user ?? user }
    private var isMe: Bool { user.id == store.me?.id }
    private var memberRoleIds: [String] { profile?.guild_member?.roles ?? [] }

    private var displayName: String {
        if let nick = profile?.guild_member?.nick, !nick.isEmpty { return nick }
        return shown.displayName
    }

    private var nameColor: Color {
        store.roleColor(guildId: guildId, userId: user.id, fallbackRoles: memberRoleIds) ?? Theme.text
    }

    private var guild: Guild? {
        guard let guildId else { return nil }
        return store.guilds.first(where: { $0.id == guildId })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 18) {
                    nameBlock
                    chipsRow
                    mutualRow
                    if !isMe && user.bot != true {
                        messageButton
                    }
                    tabHeader
                    biography
                    membership
                    rolesSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .background(Theme.chat)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.chat)
        .task {
            profile = await store.loadProfile(user, guildId: guildId)
            if let g = guildId { await store.loadRoles(g) }
        }
    }

    // MARK: Шапка

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: shown.bannerURL()) {
                bannerColor
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .clipped()
            AvatarView(user: shown, size: 92)
                .overlay(Circle().stroke(Theme.chat, lineWidth: 6))
                .offset(x: 14, y: 46)
        }
        .padding(.bottom, 50)
    }

    private var bannerColor: Color {
        if let c = shown.accent_color { return Color(hex: UInt32(c)) }
        return Theme.blurple.opacity(0.75)
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(nameColor)
                if shown.bot == true {
                    Text("APP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.blurple, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack(spacing: 6) {
                Text(shown.username)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                if let p = profile?.user_profile?.pronouns, !p.isEmpty {
                    Text("•").foregroundStyle(Theme.muted)
                    Text(p)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    /// Клановый тег и значки профиля.
    @ViewBuilder
    private var chipsRow: some View {
        let tag = shown.primary_guild?.tag ?? ""
        let badges = profile?.badges ?? []
        if !tag.isEmpty || !badges.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if !tag.isEmpty {
                        HStack(spacing: 5) {
                            RemoteImage(url: shown.primary_guild?.badgeURL, contentMode: .fit) { Color.clear }
                                .frame(width: 18, height: 18)
                            Text(tag)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.panel, in: Capsule())
                    }
                    if !badges.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(badges) { b in
                                RemoteImage(url: b.url, contentMode: .fit) { Color.clear }
                                    .frame(width: 22, height: 22)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.panel, in: Capsule())
                    }
                }
            }
        }
    }

    private var mutualText: String? {
        var parts: [String] = []
        if let f = profile?.mutual_friends_count, f > 0 {
            parts.append("\(f) \(plural(f, "общий друг", "общих друга", "общих друзей"))")
        }
        if let g = profile?.mutual_guilds?.count, g > 0 {
            parts.append("\(g) \(plural(g, "общий сервер", "общих сервера", "общих серверов"))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
    }

    @ViewBuilder
    private var mutualRow: some View {
        if let t = mutualText {
            Text(t)
                .font(.system(size: 15))
                .foregroundStyle(Theme.normalText)
        }
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10
        let m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    private var messageButton: some View {
        Button {
            dismiss()
            Task { await store.openDM(with: user) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                Text("Сообщение")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Theme.text)
        }
    }

    // MARK: Вкладка и разделы

    private var tabHeader: some View {
        VStack(spacing: 8) {
            Text("Главное")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.link)
                .frame(maxWidth: .infinity)
            Rectangle()
                .fill(Theme.link)
                .frame(height: 3)
                .clipShape(Capsule())
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .offset(y: -8)
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private var biography: some View {
        if let bio = profile?.user_profile?.bio, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Биография")
                Text(DiscordText.attributed(bio, mentions: []))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.normalText)
                    .tint(Theme.link)
            }
        }
    }

    private var membership: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(guild == nil ? "В Discord с" : "В числе участников с")
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(Theme.muted)
                Text(formatDate(snowflakeDate(user.id)))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.normalText)
                if let joined = profile?.guild_member?.joinedDate {
                    Text("•").foregroundStyle(Theme.muted)
                    if let g = guild {
                        RemoteImage(url: g.iconURL) { Theme.panel }
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(formatDate(joined))
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.normalText)
                }
            }
        }
    }

    // MARK: Роли

    @ViewBuilder
    private var rolesSection: some View {
        let ids = memberRoleIds
        let all = guildId.flatMap { store.guildRoles[$0] } ?? []
        let mine = all
            .filter { ids.contains($0.id) && $0.id != guildId }
            .sorted { ($0.position ?? 0) > ($1.position ?? 0) }
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Роли")
                FlowLayout(spacing: 8) {
                    ForEach(mine) { r in
                        roleChip(r)
                    }
                }
            }
        }
    }

    private func roleChip(_ r: GuildRole) -> some View {
        let color: Color = {
            if let c = r.color, c > 0 { return Color(hex: UInt32(c)) }
            return Theme.muted
        }()
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(r.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.normalText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Профиль сервера

struct ServerProfileSheet: View {
    @EnvironmentObject var store: Store
    let guild: Guild
    @State private var detail: GuildDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail?.name ?? guild.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    if let d = detail?.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.normalText)
                    }
                    statsRow
                    infoCard("Создан", formatDate(snowflakeDate(guild.id)))
                    if let boosts = detail?.premium_subscription_count {
                        infoCard("Бусты", "\(boosts) (уровень \(detail?.premium_tier ?? 0))")
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.chat)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.chat)
        .task {
            detail = await store.loadGuildDetail(guild.id)
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: detail?.bannerURL) {
                Theme.blurple.opacity(0.6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .clipped()
            RemoteImage(url: guild.iconURL) {
                ZStack {
                    Theme.panel
                    Text(guild.initials)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.chat, lineWidth: 6))
            .offset(x: 16, y: 38)
        }
        .padding(.bottom, 42)
    }

    @ViewBuilder
    private var statsRow: some View {
        if detail?.approximate_member_count != nil || detail?.approximate_presence_count != nil {
            HStack(spacing: 16) {
                if let online = detail?.approximate_presence_count {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.green).frame(width: 9, height: 9)
                        Text("\(online) в сети")
                    }
                }
                if let members = detail?.approximate_member_count {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.muted).frame(width: 9, height: 9)
                        Text("\(members) участников")
                    }
                }
                Spacer()
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.muted)
        }
    }

    private func infoCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(Theme.normalText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

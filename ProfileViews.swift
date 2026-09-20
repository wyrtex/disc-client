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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    names
                    if let bio = profile?.user_profile?.bio, !bio.isEmpty {
                        infoCard("Обо мне", bio)
                    }
                    infoCard("В Discord с", formatDate(snowflakeDate(user.id)))
                    if let joined = profile?.guild_member?.joinedDate {
                        infoCard("На сервере с", formatDate(joined))
                    }
                    rolesSection
                    mutualSection
                    if !isMe && user.bot != true {
                        messageButton
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
            profile = await store.loadProfile(user, guildId: guildId)
            if let g = guildId { await store.loadRoles(g) }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: shown.bannerURL()) {
                bannerColor
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .clipped()
            AvatarView(user: shown, size: 84)
                .overlay(Circle().stroke(Theme.chat, lineWidth: 6))
                .offset(x: 16, y: 42)
        }
        .padding(.bottom, 46)
    }

    private var bannerColor: Color {
        if let c = shown.accent_color { return Color(hex: UInt32(c)) }
        return Theme.blurple.opacity(0.7)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(shown.displayName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                if shown.bot == true {
                    Text("APP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.blurple, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text(shown.username)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
            if let p = profile?.user_profile?.pronouns, !p.isEmpty {
                Text(p)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
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

    @ViewBuilder
    private var rolesSection: some View {
        let ids = profile?.guild_member?.roles ?? []
        let all = guildId.flatMap { store.guildRoles[$0] } ?? []
        let mine = all
            .filter { ids.contains($0.id) && $0.id != guildId }
            .sorted { ($0.position ?? 0) > ($1.position ?? 0) }
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("РОЛИ")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.muted)
                FlowLayout(spacing: 6) {
                    ForEach(mine) { r in
                        roleChip(r)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func roleChip(_ r: GuildRole) -> some View {
        let color: Color = {
            if let c = r.color, c > 0 { return Color(hex: UInt32(c)) }
            return Theme.muted
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(r.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.normalText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.chat, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var mutualSection: some View {
        let mutual = (profile?.mutual_guilds ?? []).compactMap { m in
            store.guilds.first { $0.id == m.id }
        }
        if !mutual.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("ОБЩИЕ СЕРВЕРЫ: \(mutual.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.muted)
                ForEach(mutual) { g in
                    HStack(spacing: 10) {
                        RemoteImage(url: g.iconURL) {
                            Theme.chat
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(g.name)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.normalText)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var messageButton: some View {
        Button {
            dismiss()
            Task { await store.openDM(with: user) }
        } label: {
            HStack {
                Image(systemName: "bubble.left.fill")
                Text("Написать сообщение")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.blurple, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
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

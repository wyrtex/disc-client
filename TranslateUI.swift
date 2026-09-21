import SwiftUI

/// Окно настроек перевода для канала.
struct TranslateSettingsSheet: View {
    @EnvironmentObject var translator: Translator
    let channelId: String

    var body: some View {
        let binding = translator.binding(for: channelId)
        let s = binding.wrappedValue

        ScrollView {
            VStack(spacing: 14) {
                Text("Перевод")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !translator.pending.isEmpty {
                    card {
                        Text("Нужны языковые пакеты")
                            .font(.system(size: 15, weight: .semibold))
                        ForEach(translator.pending) { p in
                            HStack {
                                Text("\(Languages.name(p.source)) → \(Languages.name(p.target))")
                                Spacer()
                                Button("Скачать") {
                                    Task { await translator.prepare(p) }
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.blurple, in: Capsule())
                                .foregroundStyle(.white)
                            }
                        }
                        note("Пока пакет не скачан, сообщения на этом языке остаются в оригинале. Скачивает систему, дальше перевод идёт на устройстве.")
                    }
                }

                card {
                    Toggle("Переводить сообщения в чате", isOn: binding.incomingEnabled)
                        .tint(Theme.blurple)
                    if s.incomingEnabled {
                        languageRow("Переводить на", selection: binding.incomingTarget)
                        VStack(spacing: 6) {
                            HStack {
                                Text("Последних сообщений")
                                Spacer()
                                Text("\(s.count)")
                                    .foregroundStyle(Theme.muted)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(binding.wrappedValue.count) },
                                    set: { binding.wrappedValue.count = Int($0) }
                                ),
                                in: 1...100,
                                step: 1
                            )
                            .tint(Theme.blurple)
                        }
                    }
                    note("Язык каждого сообщения определяется автоматически. Когда приходит новое сообщение, самое старое за пределами выбранного числа снова показывается в оригинале.")
                }

                card {
                    Toggle("Переводить мои сообщения", isOn: binding.outgoingEnabled)
                        .tint(Theme.blurple)
                    if s.outgoingEnabled {
                        languageRow("Отправлять на языке", selection: binding.outgoingLang)
                    }
                    note("Пишешь на своём языке, а в чат уходит перевод.")
                }

                card {
                    Text("Стиль перевода")
                        .font(.system(size: 15, weight: .semibold))
                    note("Перевод повторяет стиль оригинала: если в исходном сообщении нет заглавной буквы или точки в конце, их не будет и в переводе. Остальные знаки препинания ставятся по правилам языка.")
                    note("Языковые пакеты скачиваются только по кнопке «Скачать». Сообщения на языках вне списка не переводятся и ничего не запрашивают.")
                }
            }
            .padding(16)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.panel)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
        .onDisappear { translator.resetSkips() }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chat, in: RoundedRectangle(cornerRadius: 12))
    }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func languageRow(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(Languages.all) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.link)
        }
    }
}

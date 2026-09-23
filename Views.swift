import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.me != nil {
                MainView()
            } else if store.isRestoring {
                SplashView()
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
    @State private var webStuck = false
    @State private var showVPN = false

    var body: some View {
        ZStack {
            Theme.chat.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Text("DiscClient")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.top, 60)

                    Button {
                        showWeb = true
                    } label: {
                        Text("Войти через Discord")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.blurple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Text("или вставь токен")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)

                    SecureField("Токен аккаунта", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Theme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)

                    Button {
                        Task { await store.login(token: token) }
                    } label: {
                        Group {
                            if store.isLoading { ProgressView().tint(.white) } else { Text("Войти по токену") }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.input)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(token.isEmpty || store.isLoading)

                    proxySection

                    Button {
                        showVPN = true
                    } label: {
                        Label("Встроенный VPN", systemImage: "shield.lefthalf.filled")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.input)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .sheet(isPresented: $showVPN) {
                        VPNSettingsView()
                    }

                    if let error = store.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showWeb, onDismiss: { webStuck = false }) {
            ZStack(alignment: .bottom) {
                WebLoginView(
                    onToken: { t in
                        showWeb = false
                        Task { await store.login(token: t) }
                    },
                    onStuck: { webStuck = true }
                )
                .ignoresSafeArea()

                if webStuck {
                    VStack(spacing: 10) {
                        Text("Не получается найти токен на странице")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Discord мог обновить сайт. Войди на странице как обычно и подожди ещё немного, или используй вход по токену ниже.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                        Button("Закрыть и ввести токен вручную") {
                            showWeb = false
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.blurple, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.85))
                }
            }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Использовать прокси", isOn: $store.proxy.enabled)
                .tint(Theme.blurple)
                .foregroundStyle(.white)
            if store.proxy.enabled {
                Picker("Тип", selection: $store.proxy.socks) {
                    Text("SOCKS5").tag(true)
                    Text("HTTP").tag(false)
                }
                .pickerStyle(.segmented)
                TextField("Хост", text: $store.proxy.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                TextField("Порт", value: $store.proxy.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .padding(12)
                    .background(Theme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
            }
            Text("Это ручной прокси для своих адресов. Для площадок из подписки удобнее «Встроенный VPN» ниже — он сам включает и настраивает этот прокси.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .padding(.top, 8)
    }
}


/// Пока идёт вход по сохранённому токену, показываем спокойную заставку, а не экран входа.
struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.chat.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.blurple)
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

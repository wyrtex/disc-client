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

                    if let error = store.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
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
            Text("Пока встроенного туннеля нет: включи Happ на телефоне, а прокси оставь выключенным.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .padding(.top, 8)
    }
}

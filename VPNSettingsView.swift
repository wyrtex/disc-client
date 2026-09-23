import SwiftUI

/// Встроенный VPN: список площадок из подписки, проверка «рабочая / быстрая», подключение
/// и автоматическая замена площадки, если текущая перестала пропускать трафик.
struct VPNSettingsView: View {
    @ObservedObject var vpn = VPNManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                if !vpn.libraryAvailable {
                    Section {
                        Text("Библиотека sing-box не подключена к этой сборке — проверь шаг сборки «Fetch sing-box» в build.yml.")
                            .foregroundStyle(.red)
                    }
                }

                Section("Подписка") {
                    TextField("Ссылка на подписку", text: $vpn.subscriptionURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                    Button("Обновить список площадок") {
                        Task { await vpn.loadSubscription() }
                    }
                }

                Section {
                    statusRow
                    HStack(spacing: 10) {
                        Button("Проверить площадки") {
                            Task { await vpn.testAll() }
                        }
                        .disabled(vpn.locations.isEmpty)
                        Spacer()
                        connectButton
                    }
                } header: {
                    Text("Подключение")
                } footer: {
                    Text("«Проверить» находит рабочие площадки и меряет задержку. При подключении приложение само выбирает сначала рабочую, потом среди рабочих — самую быструю, и само переключится на другую, если текущая перестанет пропускать трафик.")
                }

                if !vpn.locations.isEmpty {
                    Section("Площадки (\(vpn.locations.count))") {
                        ForEach(rankedLocations) { link in
                            locationRow(link)
                        }
                    }
                }

                Section {
                    Toggle("Подключать автоматически при запуске", isOn: $vpn.autoConnect)
                    Button("Показать журнал") { showLog = true }
                }
            }
            .navigationTitle("Встроенный VPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showLog) {
                VPNLogView(vpn: vpn)
            }
            .task {
                if vpn.locations.isEmpty, !vpn.subscriptionURL.isEmpty {
                    await vpn.loadSubscription()
                }
            }
        }
    }

    private var rankedLocations: [VLESSLink] {
        vpn.locations.sorted { a, b in
            let ra = vpn.results[a.id]
            let rb = vpn.results[b.id]
            let oka = ra?.reachable ?? false
            let okb = rb?.reachable ?? false
            if oka != okb { return oka && !okb }
            let la = ra?.latencyMs ?? Int.max
            let lb = rb?.latencyMs ?? Int.max
            if la != lb { return la < lb }
            return a.displayName < b.displayName
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch vpn.state {
        case .off:
            Label("Выключено", systemImage: "circle.fill")
                .foregroundStyle(Theme.muted)
        case .testing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Проверяю площадки…")
            }
        case .connecting(let name):
            HStack {
                ProgressView().controlSize(.small)
                Text("Подключаюсь: \(name)")
            }
        case .connected(let name):
            Label("Подключено: \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        switch vpn.state {
        case .connected, .connecting:
            Button("Отключить", role: .destructive) { vpn.disconnect() }
        default:
            Button("Подключить") {
                Task { await vpn.connectBest() }
            }
            .disabled(vpn.locations.isEmpty || !vpn.libraryAvailable)
        }
    }

    private func locationRow(_ link: VLESSLink) -> some View {
        let r = vpn.results[link.id]
        return HStack {
            Circle()
                .fill(r == nil ? Theme.muted.opacity(0.4) : (r!.reachable ? Theme.green : Color.red))
                .frame(width: 8, height: 8)
            Text(link.displayName)
                .lineLimit(1)
            Spacer()
            if let ms = r?.latencyMs {
                Text("\(ms) мс")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

struct VPNLogView: View {
    @ObservedObject var vpn: VPNManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vpn.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Theme.panel)
            .navigationTitle("Журнал VPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationBackground(Theme.panel)
    }
}

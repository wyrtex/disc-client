import Foundation
import Network
#if canImport(Libbox)
import Libbox
#endif

// MARK: - Результат проверки одной площадки

struct VPNTestResult: Equatable {
    var reachable: Bool
    var latencyMs: Int?
    var testedAt = Date()
}

enum VPNError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        }
    }
}

enum VPNState: Equatable {
    case off
    case testing
    case connecting(String)   // имя площадки
    case connected(String)
    case failed(String)
}

/// Заглушка под интерфейс PlatformInterface, который требует Go-библиотека от хост-платформы.
/// Нам не нужен системный VPN/TUN — только локальный прокси внутри процесса, поэтому почти все
/// методы здесь пустые или возвращают "не поддерживается". Если сборка укажет на этот файл —
/// значит версия sing-box ждёт другой набор методов, тогда правим точечно по тексту ошибки.
#if canImport(Libbox)
final class PlatformShim: NSObject, LibboxPlatformInterfaceProtocol {
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func usePlatformAutoDetectInterfaceControl() -> Bool { false }
    func autoDetectInterfaceControl(_ fd: Int32) throws {}
    func openTun(_ options: LibboxTunOptionsProtocol?) throws -> Int32 {
        throw VPNError.unsupported("TUN не используется: только локальный прокси")
    }
    func writeLog(_ message: String?) {
        let text = message ?? ""
        Task { @MainActor in VPNManager.shared.note(text) }
    }
    func useProcFS() -> Bool { false }
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                              destinationAddress: String?, destinationPort: Int32) throws -> Int32 {
        throw VPNError.unsupported("не поддерживается")
    }
    func packageName(byUid uid: Int32) throws -> String { throw VPNError.unsupported("не поддерживается") }
    func uid(byPackageName packageName: String?) throws -> Int32 { throw VPNError.unsupported("не поддерживается") }
    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}
    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}
    func getInterfaces() throws -> (any LibboxNetworkInterfaceIteratorProtocol)? { nil }
    func underNetworkExtension() -> Bool { false }
    func includeAllNetworks() -> Bool { false }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }
    func clearDNSCache() {}
    func sendNotification(_ notification: LibboxNotification?) throws {}
}
#endif

/// Держит и переключает локальный туннель sing-box: одна площадка активна в один момент времени,
/// на неё указывает локальный SOCKS5 на 127.0.0.1. Проверка площадок (доступна/недоступна, задержка)
/// не требует библиотеки — это обычные TCP-подключения, поэтому список можно тестировать даже
/// если сама библиотека почему-то не подключилась к сборке.
@MainActor
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var state: VPNState = .off
    @Published var locations: [VLESSLink] = []
    @Published var results: [String: VPNTestResult] = [:]
    @Published var log: [String] = []
    @Published var subscriptionURL: String = UserDefaults.standard.string(forKey: "vpnSubURL") ?? ""
    @Published var autoConnect = UserDefaults.standard.bool(forKey: "vpnAuto") {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "vpnAuto") }
    }

    let localPort = 10808
    var onProxyChange: ((ProxySettings) -> Void)?

    #if canImport(Libbox)
    private var service: LibboxBoxService?
    #endif
    private var currentLink: VLESSLink?
    private var healthTask: Task<Void, Never>?
    private var reconnecting = false

    var libraryAvailable: Bool {
        #if canImport(Libbox)
        return true
        #else
        return false
        #endif
    }

    private init() {
        if let saved = UserDefaults.standard.data(forKey: "vpnLocations"),
           let list = try? JSONDecoder().decode([VLESSLink].self, from: saved) {
            locations = list
        }
    }

    func note(_ s: String) {
        log.append(VPNManager.timeFormat.string(from: Date()) + "  " + s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Подписка

    func loadSubscription() async {
        let urlString = subscriptionURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            note("Ссылка на подписку не задана")
            return
        }
        UserDefaults.standard.set(urlString, forKey: "vpnSubURL")
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: req)
            let text = String(data: data, encoding: .utf8) ?? ""
            let list = VLESSParser.parseSubscription(text)
            guard !list.isEmpty else {
                note("В подписке не нашлось ни одной ссылки vless+reality")
                return
            }
            locations = list
            if let saved = try? JSONEncoder().encode(list) {
                UserDefaults.standard.set(saved, forKey: "vpnLocations")
            }
            note("Подписка обновлена: \(list.count) площадок")
        } catch {
            note("Не удалось загрузить подписку: \(error.localizedDescription)")
        }
    }

    // MARK: Проверка площадок (обычный TCP-коннект, без библиотеки)

    func testAll() async {
        guard !locations.isEmpty else { return }
        state = .testing
        note("Проверяю \(locations.count) площадок…")
        let limiter = AsyncLimiter(limit: 12)
        await withTaskGroup(of: (String, VPNTestResult).self) { group in
            for link in locations {
                group.addTask {
                    await limiter.acquire()
                    let r = await VPNManager.testTCP(host: link.host, port: link.port)
                    await limiter.release()
                    return (link.id, r)
                }
            }
            for await (id, r) in group {
                results[id] = r
            }
        }
        let ok = results.values.filter { $0.reachable }.count
        note("Проверка закончена: доступно \(ok) из \(locations.count)")
        if case .testing = state { state = .off }
    }

    private static func testTCP(host: String, port: Int) async -> VPNTestResult {
        await withCheckedContinuation { cont in
            let start = Date()
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
            var done = false
            let finish: (Bool) -> Void = { ok in
                guard !done else { return }
                done = true
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                conn.cancel()
                cont.resume(returning: VPNTestResult(reachable: ok, latencyMs: ok ? ms : nil))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(false) }
        }
    }

    /// Сначала рабочие, среди рабочих — самые быстрые.
    private func ranked() -> [VLESSLink] {
        locations.sorted { a, b in
            let ra = results[a.id]
            let rb = results[b.id]
            let oka = ra?.reachable ?? false
            let okb = rb?.reachable ?? false
            if oka != okb { return oka && !okb }
            let la = ra?.latencyMs ?? Int.max
            let lb = rb?.latencyMs ?? Int.max
            return la < lb
        }
    }

    // MARK: Подключение (с автозаменой при неудаче)

    /// Пробует площадки по порядку "сначала рабочие → среди рабочих быстрые" и включает первую,
    /// через которую реально проходит запрос к интернету. Если не получилось — сама переходит к следующей.
    func connectBest() async {
        guard libraryAvailable else {
            state = .failed("Библиотека sing-box не подключена к этой сборке")
            return
        }
        if results.isEmpty { await testAll() }
        let candidates = ranked()
        guard !candidates.isEmpty else {
            state = .failed("Нет площадок для подключения")
            return
        }
        for link in candidates {
            state = .connecting(link.displayName)
            note("Пробую площадку: \(link.displayName) (\(link.host))")
            stopService()
            do {
                try startService(link)
                let ok = await verifyThroughProxy()
                if ok {
                    currentLink = link
                    state = .connected(link.displayName)
                    note("Подключено: \(link.displayName)")
                    onProxyChange?(ProxySettings(enabled: true, host: "127.0.0.1", port: localPort, socks: true))
                    startHealthMonitor()
                    return
                }
                note("Площадка \(link.displayName) не пропускает трафик, пробую следующую")
                stopService()
            } catch {
                note("Площадка \(link.displayName): \(error.localizedDescription)")
                stopService()
            }
        }
        state = .failed("Ни одна площадка не заработала")
        onProxyChange?(ProxySettings(enabled: false, host: "127.0.0.1", port: localPort, socks: true))
    }

    func disconnect() {
        healthTask?.cancel()
        healthTask = nil
        stopService()
        currentLink = nil
        state = .off
        onProxyChange?(ProxySettings(enabled: false, host: "127.0.0.1", port: localPort, socks: true))
        note("Отключено")
    }

    /// Реальная проверка: запрос через только что поднятый локальный прокси, а не просто TCP до сервера.
    private func verifyThroughProxy() async -> Bool {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": localPort
        ]
        cfg.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: cfg)
        guard let url = URL(string: "https://discord.com/api/v9/gateway") else { return false }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            if let (_, resp) = try? await session.data(from: url),
               let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                return true
            }
        }
        return false
    }

    /// Пока подключены, время от времени тихо проверяем, что прокси ещё жив; если нет — сами переключаемся.
    private func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, case .connected = self.state, !self.reconnecting else { continue }
                let ok = await self.verifyThroughProxy()
                if !ok {
                    self.reconnecting = true
                    self.note("Площадка перестала отвечать, переключаюсь автоматически…")
                    if let bad = self.currentLink { self.results[bad.id] = VPNTestResult(reachable: false, latencyMs: nil) }
                    await self.connectBest()
                    self.reconnecting = false
                }
            }
        }
    }

    // MARK: Сам процесс sing-box

    private func startService(_ link: VLESSLink) throws {
        #if canImport(Libbox)
        let config = SingBoxConfig.build(link: link, localPort: localPort)
        let shim = PlatformShim()
        let s = try LibboxNewService(config, shim)
        try s.start()
        service = s
        #else
        throw VPNError.unsupported("библиотека недоступна")
        #endif
    }

    private func stopService() {
        #if canImport(Libbox)
        try? service?.close()
        service = nil
        #endif
    }
}

import Foundation

/// Транспорт кадров между расширением трансляции и приложением.
///
/// Раньше это был Unix-domain-сокет в папке App Group, но под ESign App Group не подписывается,
/// и путь к сокету получить нельзя. Поэтому гоним кадры по локальному TCP на 127.0.0.1:<порт> —
/// это работает между приложением и его расширением на одном устройстве без App Group.
/// Формат потока прежний: [4 байта длины][1 байт тип][данные].

/// Клиент (сторона расширения): подключается к приложению и шлёт кадры.
final class LocalSocketClient {
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "broadcast.socket.client")
    var onConnected: (() -> Void)?

    func connect() {
        queue.async { self.tryConnect() }
    }

    private func tryConnect() {
        // Приложение поднимает слушатель ещё до запуска расширения, но на всякий случай — с ретраями.
        for attempt in 0..<40 {
            if connectOnce() {
                BroadcastShared.extLog("сокет: подключился к приложению (попытка \(attempt + 1))")
                onConnected?()
                return
            }
            usleep(100_000) // 0.1 c
        }
        BroadcastShared.extLog("сокет: не удалось подключиться к приложению за 4 с")
    }

    private func connectOnce() -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = BroadcastShared.socketPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, size) }
        }
        if ok != 0 {
            Darwin.close(s)
            return false
        }
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        return true
    }

    func send(_ data: Data) {
        queue.async {
            guard self.fd >= 0 else { return }
            var sent = 0
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while sent < data.count {
                    let n = Darwin.send(self.fd, base + sent, data.count - sent, Int32(MSG_NOSIGNAL))
                    if n <= 0 { Darwin.close(self.fd); self.fd = -1; break }
                    sent += n
                }
            }
        }
    }

    func close() {
        queue.async {
            if self.fd >= 0 { Darwin.close(self.fd); self.fd = -1 }
        }
    }
}

/// Сервер (сторона приложения): принимает подключение расширения и собирает кадры
/// из потока [длина][тип][данные], отдаёт их через onFrame.
final class LocalSocketServer {
    var onFrame: ((_ type: UInt8, _ payload: Data) -> Void)?
    var onConnect: (() -> Void)?

    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let queue = DispatchQueue(label: "broadcast.socket.server")
    private var running = false
    private var buffer = Data()

    func start() {
        queue.async { self.setup() }
    }

    private func setup() {
        if running { return }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = BroadcastShared.socketPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, size) }
        }
        guard bound == 0, listen(s, 1) == 0 else {
            Darwin.close(s); return
        }
        listenFd = s
        running = true
        acceptLoop()
    }

    private func acceptLoop() {
        queue.async {
            while self.running {
                let fd = accept(self.listenFd, nil, nil)
                if fd < 0 { break }
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                self.clientFd = fd
                self.buffer = Data()
                DispatchQueue.main.async { self.onConnect?() }
                self.readLoop(fd)
            }
        }
    }

    private func readLoop(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while running {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            drain()
        }
        Darwin.close(fd)
        if clientFd == fd { clientFd = -1 }
    }

    private func drain() {
        while buffer.count >= 4 {
            let len = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let total = Int(len)
            guard total >= 1, buffer.count >= 4 + total else { break }
            let type = buffer[buffer.index(buffer.startIndex, offsetBy: 4)]
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 5)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: 4 + total)
            let payload = Data(buffer[payloadStart..<payloadEnd])
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
            onFrame?(type, payload)
        }
    }

    func stop() {
        queue.async {
            self.running = false
            if self.clientFd >= 0 { Darwin.close(self.clientFd); self.clientFd = -1 }
            if self.listenFd >= 0 { Darwin.close(self.listenFd); self.listenFd = -1 }
        }
    }
}

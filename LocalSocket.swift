import Foundation

/// Клиент локального сокета (сторона расширения): подключается к сокету приложения и шлёт кадры.
/// Unix domain socket в общей папке App Group — самый надёжный способ гнать поток кадров
/// между процессами на устройстве без ограничений памяти расширения.
final class LocalSocketClient {
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "broadcast.socket.client")

    func connect() {
        queue.async { self.tryConnect() }
    }

    private func tryConnect() {
        guard let url = BroadcastShared.socketURL() else { return }
        let path = url.path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            path.withCString { src in strncpy(dst, src, 104) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        if ok != 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    func send(_ data: Data) {
        queue.async {
            guard self.fd >= 0 else { return }
            var sent = 0
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while sent < data.count {
                    let n = Darwin.send(self.fd, base + sent, data.count - sent, Int32(MSG_NOSIGNAL))
                    if n <= 0 { self.fd = -1; break }
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

/// Сервер локального сокета (сторона приложения): принимает подключение расширения и собирает
/// кадры из потока [длина][тип][данные]. Отдаёт готовые кадры через onFrame.
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
        guard let url = BroadcastShared.socketURL() else { return }
        let path = url.path
        unlink(path)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            path.withCString { src in strncpy(dst, src, 104) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFd, $0, size) }
        }
        guard bound == 0, listen(listenFd, 1) == 0 else {
            Darwin.close(listenFd); listenFd = -1; return
        }
        running = true
        acceptLoop()
    }

    private func acceptLoop() {
        queue.async {
            while self.running {
                let fd = accept(self.listenFd, nil, nil)
                if fd < 0 { break }
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

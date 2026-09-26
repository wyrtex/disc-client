import Foundation

/// Общие константы для связи основного приложения и расширения трансляции экрана.
/// App Group нужен, чтобы делить настройки (качество/звук/блюр) и локальный сокет.
enum BroadcastShared {
    static let appGroup = "group.com.example.discclient"
    /// Файл-сокет (Unix domain socket) в общей папке — по нему расширение шлёт кадры в приложение.
    static let socketName = "broadcast.sock"
    /// Под ESign App Group недоступен, поэтому кадры гоним по локальному TCP на 127.0.0.1.
    /// Порт из «динамического» диапазона, чтобы ни с чем не конфликтовать.
    static let socketPort: UInt16 = 48291

    // Ключи настроек в общем UserDefaults
    static let keyQuality = "stream.quality"      // "default" | "high"
    static let keyStreamAudio = "stream.audio"    // Bool
    static let keyBlur = "stream.blur"            // Bool — включён ли блюр прямо сейчас
    static let keyRecord = "stream.record"
    static let keyLastRecording = "stream.lastRecording"

    // Имена межпроцессных уведомлений (Darwin notifications) для управления блюром на лету.
    static let notifyBlurOn = "com.example.discclient.blur.on"
    static let notifyBlurOff = "com.example.discclient.blur.off"
    static let notifyBlurToggle = "com.example.discclient.blur.toggle"
    // Расширение → приложение: трансляция началась/закончилась.
    static let notifyStarted = "com.example.discclient.broadcast.started"
    static let notifyStopped = "com.example.discclient.broadcast.stopped"
    // Команда приложения расширению: заверши трансляцию (пользователь нажал «остановить» в приложении).
    static let notifyStopCommand = "com.example.discclient.broadcast.stopCommand"
    static let notifyRecordingReady = "com.example.discclient.broadcast.recordingReady"
    // Диагностические «маячки» расширения (Darwin работает без App Group): показывают, до какого
    // шага дошло расширение. Приложение их слушает и пишет в свой лог.
    static let beaconStarted = "com.example.discclient.broadcast.beacon.started"
    static let beaconFirstVideo = "com.example.discclient.broadcast.beacon.firstvideo"
    static let beaconSocketOK = "com.example.discclient.broadcast.beacon.socketok"
    static let beaconFirstSend = "com.example.discclient.broadcast.beacon.firstsend"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Общий файл-журнал расширения: расширение не может писать в наш экранный лог напрямую
    /// (это другой процесс), поэтому пишем строки в файл App Group, а приложение их читает.
    static func logURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("ext.log")
    }

    /// Дозаписать строку в журнал расширения. Работает даже если App Group недоступна —
    /// тогда просто ничего не пишет (и это само по себе будет сигналом).
    static func extLog(_ line: String) {
        guard let url = logURL() else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)  \(line)\n"
        if let data = entry.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? entry.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func clearExtLog() {
        guard let url = logURL() else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    static func readExtLog() -> String {
        guard let url = logURL(), let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    static func socketURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(socketName)
    }

    enum Quality: String {
        case standard = "default"
        case high

        var width: Int { self == .high ? 1920 : 1280 }
        var height: Int { self == .high ? 1080 : 720 }
        var fps: Int { self == .high ? 60 : 30 }
        var bitrate: Int { self == .high ? 6_000_000 : 2_500_000 }
    }

    static var quality: Quality {
        Quality(rawValue: defaults?.string(forKey: keyQuality) ?? "default") ?? .standard
    }
    static var streamAudio: Bool { defaults?.bool(forKey: keyStreamAudio) ?? false }
    static var blur: Bool { defaults?.bool(forKey: keyBlur) ?? false }
    static var record: Bool { defaults?.bool(forKey: keyRecord) ?? false }

    // MARK: Darwin notifications

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true
        )
    }

    static func observe(_ name: String, _ handler: @escaping () -> Void) -> NSObjectProtocol {
        let cf = CFNotificationCenterGetDarwinNotifyCenter()
        let token = Unmanaged.passRetained(Box(handler)).toOpaque()
        CFNotificationCenterAddObserver(cf, token, { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue()
            box.handler()
        }, name as CFString, nil, .deliverImmediately)
        return NotificationToken(pointer: token, name: name)
    }

    private final class Box { let handler: () -> Void; init(_ h: @escaping () -> Void) { handler = h } }

    private final class NotificationToken: NSObject {
        let pointer: UnsafeMutableRawPointer
        let cfName: String
        init(pointer: UnsafeMutableRawPointer, name: String) { self.pointer = pointer; self.cfName = name }
        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), pointer,
                CFNotificationName(cfName as CFString), nil
            )
            Unmanaged<Box>.fromOpaque(pointer).release()
        }
    }
}

/// Простой кадровый протокол поверх локального сокета: [4 байта длины][тип:1][данные].
/// Тип 0 = видео H264 Annex-B кадр, тип 1 = PCM-аудио (не используется на первом этапе).
enum BroadcastWire {
    static let typeVideo: UInt8 = 0
    static let typeAudio: UInt8 = 1

    static func frame(type: UInt8, _ payload: Data) -> Data {
        var out = Data()
        var len = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(type)
        out.append(payload)
        return out
    }
}

import Foundation

/// Обёртка над libdave (Discord DAVE). Если библиотека не собралась, все функции возвращают заглушки.
enum DaveLib {
    static var isBuiltIn: Bool {
        #if DAVE
        return true
        #else
        return false
        #endif
    }

    /// Самопроверка: версия протокола, создание сессии MLS, генерация ключевого пакета, создание шифратора.
    static func selfTest() -> [String] {
        #if DAVE
        var out: [String] = []
        let version = daveMaxSupportedProtocolVersion()
        out.append("libdave подключена. Максимальная версия протокола: \(version)")

        let failure: DAVEMLSFailureCallback = { source, reason, _ in
            let s = source.map { String(cString: $0) } ?? "?"
            let r = reason.map { String(cString: $0) } ?? "?"
            print("DAVE MLS failure: \(s): \(r)")
        }

        guard let session = daveSessionCreate(nil, nil, failure, nil) else {
            out.append("Не удалось создать сессию DAVE")
            return out
        }
        defer { daveSessionDestroy(session) }

        daveSessionInit(session, version, 123456789, "987654321")
        var keyPackage: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        daveSessionGetMarshalledKeyPackage(session, &keyPackage, &length)
        out.append("Сессия MLS создана, ключевой пакет: \(length) байт")
        if let keyPackage { daveFree(keyPackage) }

        if let enc = daveEncryptorCreate() {
            out.append("Шифратор создан, ключа пока нет: \(!daveEncryptorHasKeyRatchet(enc))")
            daveEncryptorDestroy(enc)
        }
        return out
        #else
        return ["Библиотека DAVE не собрана в этой сборке приложения."]
        #endif
    }
}

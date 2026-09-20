import Foundation

/// Конечный автомат DAVE (сквозное шифрование голоса Discord) поверх libdave.
/// Повторяет логику официального примера DaveSessionManager из репозитория libdave.
/// Если библиотека не собрана, `init` возвращает nil.
final class DaveSession {
    var sendJSON: (([String: Any]) -> Void)?
    var sendBinary: ((Data) -> Void)?
    var log: ((String) -> Void)?
    /// Вызывается, когда для нас готов ключ шифрования (можно отправлять зашифрованный звук).
    var onEncryptionReady: ((Int) -> Void)?

    #if DAVE

    private var handle: DAVESessionHandle?
    private let selfUserId: String
    private let groupId: UInt64
    private var recognized = Set<String>()
    private var transitions: [Int: Int] = [:]
    private var latestPreparedVersion = 0
    private let lock = NSRecursiveLock()

    private static let initTransitionId = 0
    private static let disabledVersion = 0

    init?(selfUserId: String, channelId: String) {
        guard let gid = UInt64(channelId) else { return nil }
        self.selfUserId = selfUserId
        self.groupId = gid

        let failure: DAVEMLSFailureCallback = { source, reason, user in
            guard let user else { return }
            let me = Unmanaged<DaveSession>.fromOpaque(user).takeUnretainedValue()
            let s = source.map { String(cString: $0) } ?? "?"
            let r = reason.map { String(cString: $0) } ?? "?"
            me.log?("DAVE MLS ошибка: \(s): \(r)")
        }
        guard let h = daveSessionCreate(nil, nil, failure, Unmanaged.passUnretained(self).toOpaque()) else {
            return nil
        }
        handle = h
    }

    deinit {
        if let h = handle { daveSessionDestroy(h) }
    }

    // MARK: Входящие события голосового шлюза

    func userConnected(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids where id != selfUserId {
            recognized.insert(id)
            setupKeyRatchet(userId: id, version: latestPreparedVersion)
        }
    }

    func userDisconnected(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        recognized.remove(id)
    }

    /// op 4 (Session Description): начинаем рукопожатие, если сервер согласился на DAVE.
    func onSessionDescription(version: Int) {
        lock.lock(); defer { lock.unlock() }
        handleInit(version: version)
    }

    /// op 21
    func onPrepareTransition(id: Int, version: Int) {
        lock.lock(); defer { lock.unlock() }
        prepareRatchets(transitionId: id, version: version)
        maybeSendReady(transitionId: id)
    }

    /// op 22
    func onExecuteTransition(id: Int) {
        lock.lock(); defer { lock.unlock() }
        executeTransition(id: id)
    }

    /// op 24
    func onPrepareEpoch(epoch: Int, version: Int) {
        lock.lock(); defer { lock.unlock() }
        handlePrepareEpoch(epoch: epoch, version: version)
        if epoch == 1 { sendKeyPackage() }
    }

    /// op 25
    func onExternalSender(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            daveSessionSetExternalSender(h, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        log?("DAVE: внешний отправитель установлен")
    }

    /// op 27
    func onProposals(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let commitWelcome = processProposals(data) {
            log?("DAVE: предложения обработаны, отправляю commit/welcome (\(commitWelcome.count) байт)")
            sendBinary?(Data([28]) + commitWelcome)
        } else {
            log?("DAVE: предложения обработаны, ответа не требуется")
        }
    }

    /// op 29
    func onAnnounceCommit(id: Int, commit: Data) {
        lock.lock(); defer { lock.unlock() }
        switch processCommit(commit) {
        case .ignored:
            log?("DAVE: commit проигнорирован (transition \(id))")
        case .failed:
            log?("DAVE: commit не удалось применить (transition \(id)), начинаю заново")
            flagInvalid(transitionId: id)
            handleInit(version: currentVersion())
        case .joined(let roster):
            log?("DAVE: commit применён, участников в группе MLS: \(roster.count) (transition \(id))")
            prepareRatchets(transitionId: id, version: currentVersion())
            maybeSendReady(transitionId: id)
        }
    }

    /// op 30
    func onWelcome(id: Int, welcome: Data) {
        lock.lock(); defer { lock.unlock() }
        if let roster = processWelcome(welcome) {
            log?("DAVE: welcome принят, участников в группе MLS: \(roster.count) (transition \(id))")
            prepareRatchets(transitionId: id, version: currentVersion())
            maybeSendReady(transitionId: id)
        } else {
            log?("DAVE: welcome не удалось применить (transition \(id))")
            flagInvalid(transitionId: id)
            sendKeyPackage()
        }
    }

    // MARK: Логика протокола

    private func currentVersion() -> Int {
        guard let h = handle else { return 0 }
        return Int(daveSessionGetProtocolVersion(h))
    }

    private func handleInit(version: Int) {
        if version > 0 {
            log?("DAVE: сервер включил E2EE (версия протокола \(version)), начинаю обмен ключами")
            handlePrepareEpoch(epoch: 1, version: version)
            sendKeyPackage()
        } else {
            log?("DAVE: E2EE на этом канале выключено (версия 0)")
            prepareRatchets(transitionId: DaveSession.initTransitionId, version: version)
            executeTransition(id: DaveSession.initTransitionId)
        }
    }

    private func handlePrepareEpoch(epoch: Int, version: Int) {
        guard epoch == 1, let h = handle else { return }
        daveSessionInit(h, UInt16(clamping: version), groupId, selfUserId)
        log?("DAVE: сессия MLS инициализирована (канал \(groupId))")
    }

    private func executeTransition(id: Int) {
        guard let version = transitions.removeValue(forKey: id) else { return }
        if version == DaveSession.disabledVersion, let h = handle {
            daveSessionReset(h)
        }
        setupKeyRatchet(userId: selfUserId, version: version)
    }

    private func prepareRatchets(transitionId: Int, version: Int) {
        for id in recognized where id != selfUserId {
            setupKeyRatchet(userId: id, version: version)
        }
        if transitionId == DaveSession.initTransitionId {
            setupKeyRatchet(userId: selfUserId, version: version)
        } else {
            transitions[transitionId] = version
        }
        latestPreparedVersion = version
    }

    private func setupKeyRatchet(userId: String, version: Int) {
        guard let h = handle else { return }
        if version == DaveSession.disabledVersion {
            if userId == selfUserId { log?("DAVE: шифрование отключено, звук пойдёт без E2EE") }
            return
        }
        guard let ratchet = daveSessionGetKeyRatchet(h, userId) else {
            log?("DAVE: не удалось получить ключ для \(userId)")
            return
        }
        // На этом этапе ключи только проверяем. Шифратор и дешифраторы подключим, когда дойдём до звука.
        daveKeyRatchetDestroy(ratchet)
        if userId == selfUserId {
            log?("DAVE: ключ шифрования для нас готов (версия \(version))")
            onEncryptionReady?(version)
        }
    }

    private func maybeSendReady(transitionId: Int) {
        guard transitionId != DaveSession.initTransitionId else { return }
        log?("DAVE: отправляю op 23 (готов к transition \(transitionId))")
        sendJSON?(["op": 23, "d": ["transition_id": transitionId]])
    }

    private func flagInvalid(transitionId: Int) {
        sendJSON?(["op": 31, "d": ["transition_id": transitionId]])
    }

    private func sendKeyPackage() {
        guard let h = handle else { return }
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n: Int = 0
        daveSessionGetMarshalledKeyPackage(h, &p, &n)
        guard let p, n > 0 else {
            log?("DAVE: не удалось получить ключевой пакет")
            return
        }
        let kp = Data(bytes: p, count: n)
        daveFree(p)
        log?("DAVE: отправляю ключевой пакет (op 26, \(kp.count) байт)")
        sendBinary?(Data([26]) + kp)
    }

    // MARK: Обёртки над C API

    private func withRecognized<R>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>?, Int) -> R) -> R {
        let ids = Array(recognized.union([selfUserId]))
        let cstrs: [UnsafeMutablePointer<CChar>?] = ids.map { strdup($0) }
        defer { for p in cstrs { free(p) } }
        var ptrs: [UnsafePointer<CChar>?] = cstrs.map { UnsafePointer($0) }
        return ptrs.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress, ids.count)
        }
    }

    private func processProposals(_ data: Data) -> Data? {
        guard let h = handle else { return nil }
        var out: UnsafeMutablePointer<UInt8>? = nil
        var outLen: Int = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self).baseAddress
            withRecognized { ids, n in
                daveSessionProcessProposals(h, p, data.count, ids, n, &out, &outLen)
            }
        }
        guard let out, outLen > 0 else { return nil }
        let d = Data(bytes: out, count: outLen)
        daveFree(out)
        return d
    }

    private enum CommitOutcome {
        case failed
        case ignored
        case joined([UInt64])
    }

    private func processCommit(_ data: Data) -> CommitOutcome {
        guard let h = handle else { return .failed }
        var result: DAVECommitResultHandle?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            result = daveSessionProcessCommit(h, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard let r = result else { return .failed }
        defer { daveCommitResultDestroy(r) }
        if daveCommitResultIsFailed(r) { return .failed }
        if daveCommitResultIsIgnored(r) { return .ignored }
        var ids: UnsafeMutablePointer<UInt64>? = nil
        var n: Int = 0
        daveCommitResultGetRosterMemberIds(r, &ids, &n)
        var roster: [UInt64] = []
        if let ids {
            roster = Array(UnsafeBufferPointer(start: ids, count: n))
            daveFree(ids)
        }
        return .joined(roster)
    }

    private func processWelcome(_ data: Data) -> [UInt64]? {
        guard let h = handle else { return nil }
        var result: DAVEWelcomeResultHandle?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self).baseAddress
            result = withRecognized { ids, n in
                daveSessionProcessWelcome(h, p, data.count, ids, n)
            }
        }
        guard let r = result else { return nil }
        defer { daveWelcomeResultDestroy(r) }
        var ids: UnsafeMutablePointer<UInt64>? = nil
        var n: Int = 0
        daveWelcomeResultGetRosterMemberIds(r, &ids, &n)
        var roster: [UInt64] = []
        if let ids {
            roster = Array(UnsafeBufferPointer(start: ids, count: n))
            daveFree(ids)
        }
        return roster
    }

    #else

    init?(selfUserId: String, channelId: String) { return nil }
    func userConnected(_ ids: [String]) {}
    func userDisconnected(_ id: String) {}
    func onSessionDescription(version: Int) {}
    func onPrepareTransition(id: Int, version: Int) {}
    func onExecuteTransition(id: Int) {}
    func onPrepareEpoch(epoch: Int, version: Int) {}
    func onExternalSender(_ data: Data) {}
    func onProposals(_ data: Data) {}
    func onAnnounceCommit(id: Int, commit: Data) {}
    func onWelcome(id: Int, welcome: Data) {}

    #endif
}

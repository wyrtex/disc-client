import Foundation
import Speech
import AVFoundation
import NaturalLanguage

/// Общий интерфейс распознавания. Аудио приходит моно, 48 кГц.
protocol TranscribeBackend: AnyObject {
    func append(userId: String, mono: [Float])
    func endUtterance(userId: String)
    func endAll()
    func shutdown()
}

/// Субтитры голоса. Для каждого участника своя сессия распознавания.
/// iOS 26+: SpeechAnalyzer с автоопределением языка среди включённых языков.
/// Раньше: Apple Speech (SFSpeechRecognizer) с первым включённым языком.
final class VoiceTranscriber {
    struct Update {
        let userId: String
        let text: String
        let isFinal: Bool
        let lang: String?
    }

    var onUpdate: ((Update) -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "voice.transcriber")
    private var backend: TranscribeBackend?
    private var enabled = false
    private var streams: [String: UserStream] = [:]
    private var timer: DispatchSourceTimer?

    private struct UserStream {
        var lastTs: UInt32
        var lastCount: Int
        var lastArrival: Date
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// `locales`: языки, среди которых определяется речь (например ["ru-RU", "en-US"]).
    func configure(enabled: Bool, locales: [String]) {
        queue.async {
            self.backend?.shutdown()
            self.backend = nil
            self.streams = [:]
            self.enabled = enabled
            guard enabled, !locales.isEmpty else {
                self.stopTimer()
                return
            }
            self.backend = self.makeBackend(locales: locales)
            self.startTimer()
        }
    }

    /// Вызывается при выходе из канала: завершаем текущие реплики.
    func reset() {
        queue.async {
            self.backend?.endAll()
            self.streams = [:]
        }
    }

    /// Аудио участника (из медиа-потока). Стерео или моно, 48 кГц.
    /// По RTP-меткам времени восстанавливаем паузы: Discord не шлёт пакеты в тишине,
    /// а распознавателю нужна нормальная временная шкала.
    func feed(userId: String, interleaved: [Float], channels: Int, frames: Int, rtpTimestamp: UInt32) {
        queue.async {
            guard self.enabled, let backend = self.backend,
                  frames > 0, interleaved.count >= frames * channels else { return }

            var mono = [Float](repeating: 0, count: frames)
            if channels == 2 {
                for i in 0..<frames {
                    mono[i] = (interleaved[2 * i] + interleaved[2 * i + 1]) * 0.5
                }
            } else {
                for i in 0..<frames { mono[i] = interleaved[i] }
            }

            if let s = self.streams[userId] {
                let expected = s.lastTs &+ UInt32(truncatingIfNeeded: s.lastCount)
                let gap = Int(Int32(bitPattern: rtpTimestamp &- expected))
                if gap > 480 && gap <= 48_000 {
                    backend.append(userId: userId, mono: [Float](repeating: 0, count: gap))
                } else if gap > 48_000 {
                    backend.endUtterance(userId: userId)
                }
            }
            backend.append(userId: userId, mono: mono)
            self.streams[userId] = UserStream(lastTs: rtpTimestamp, lastCount: frames, lastArrival: Date())
        }
    }

    // MARK: Внутреннее

    private func makeBackend(locales: [String]) -> TranscribeBackend? {
        let update: (Update) -> Void = { [weak self] u in self?.onUpdate?(u) }
        let status: (String) -> Void = { [weak self] s in self?.onStatus?(s) }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return AnalyzerBackend(locales: locales, onUpdate: update, onStatus: status)
        }
        #endif
        return LegacyBackend(localeId: locales[0], onUpdate: update, onStatus: status)
    }

    private func startTimer() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 0.3)
        t.setEventHandler { [weak self] in
            guard let self, let backend = self.backend else { return }
            let now = Date()
            for (uid, s) in self.streams where now.timeIntervalSince(s.lastArrival) > 1.4 {
                backend.endUtterance(userId: uid)
                self.streams[uid] = nil
            }
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Определение языка по тексту

enum SpeechLang {
    /// Код языка для NaturalLanguage и для перевода: ru-RU -> ru, zh-CN -> zh-Hans.
    static func code(_ locale: String) -> String {
        if locale.hasPrefix("zh") { return "zh-Hans" }
        return String(locale.prefix(2))
    }

    static func name(_ locale: String) -> String {
        TranscriptLanguage.all.first(where: { $0.code == locale })?.name ?? locale
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    /// Вероятность того, что текст написан на этом языке.
    static func probability(_ text: String, locale: String) -> Double {
        let r = NLLanguageRecognizer()
        r.processString(text)
        let hyp = r.languageHypotheses(withMaximum: 6)
        return hyp[NLLanguage(rawValue: code(locale))] ?? 0
    }

    /// Насколько результат похож на настоящую речь на этом языке.
    static func score(_ text: String, locale: String) -> Double {
        let w = words(text)
        guard w > 0 else { return 0 }
        return Double(min(w, 10)) * (0.15 + probability(text, locale: locale))
    }
}

// MARK: - iOS 26: SpeechAnalyzer с автоопределением языка

/// Выполняет `operation`; если она не укладывается в `seconds`, отменяет её и возвращает nil,
/// не дожидаясь зависшего вызова. Так подвисшая модель одного участника не блокирует остальных.
private func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            try? await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        // group.next() отдаёт T?? — nil снаружи означает "задач не осталось" (не должно случиться,
        // их всегда две), поэтому схлопываем в T? через ?? nil.
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

#if compiler(>=6.2)

/// Общий предел одновременно живых моделей распознавания на всех участников сразу —
/// чтобы 5+ человек одновременно не запускали по 4 модели каждый и не душили телефон.
@available(iOS 26.0, *)
private actor AnalyzerGate {
    private var used = 0
    private let limit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if used < limit {
            used += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            used = max(0, used - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Языки, для которых модель уже скачана и готова. Общая для всех участников, заполняется один раз.
@available(iOS 26.0, *)
private actor ReadyLocales {
    private var map: [String: Locale] = [:]

    func set(_ id: String, _ l: Locale) { map[id] = l }
    func get(_ id: String) -> Locale? { map[id] }
    var ids: Set<String> { Set(map.keys) }
}

@available(iOS 26.0, *)
final class AnalyzerBackend: TranscribeBackend {
    private let enabled: [String]
    private let onUpdate: (VoiceTranscriber.Update) -> Void
    private let onStatus: (String) -> Void
    private let ready = ReadyLocales()
    private let gate = AnalyzerGate(limit: 4)
    private var prepareTask: Task<Void, Never>?
    private var pipelines: [String: UserPipeline] = [:]
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    init(locales: [String], onUpdate: @escaping (VoiceTranscriber.Update) -> Void, onStatus: @escaping (String) -> Void) {
        self.enabled = locales
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        prepareTask = Task { [weak self] in await self?.prepareAll() }
    }

    /// Своя независимая "дорожка" на каждого участника: у неё свой Task и своя очередь команд,
    /// так что зависание у одного человека физически не может задержать субтитры другого.
    private func pipeline(for uid: String) -> UserPipeline {
        if let p = pipelines[uid] { return p }
        let p = UserPipeline(
            userId: uid,
            enabledLocales: enabled,
            ready: ready,
            gate: gate,
            sourceFormat: sourceFormat,
            onUpdate: onUpdate,
            onStatus: onStatus
        )
        pipelines[uid] = p
        return p
    }

    func append(userId: String, mono: [Float]) {
        pipeline(for: userId).enqueueAudio(mono)
    }

    func endUtterance(userId: String) {
        pipelines[userId]?.enqueueEnd()
    }

    func endAll() {
        for p in pipelines.values { p.enqueueEnd() }
    }

    func shutdown() {
        prepareTask?.cancel()
        for p in pipelines.values { p.shutdown() }
        pipelines = [:]
    }

    private func prepareAll() async {
        for (i, id) in enabled.enumerated() {
            if Task.isCancelled { return }
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                onStatus("Язык «\(SpeechLang.name(id))» не поддерживается распознаванием")
                continue
            }
            do {
                let t = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                    onStatus("Скачиваю язык: \(SpeechLang.name(id)) (\(i + 1) из \(enabled.count))…")
                    try await request.downloadAndInstall()
                }
                await ready.set(id, supported)
                let count = await ready.ids.count
                onStatus("Распознавание речи: авто, готово языков: \(count) из \(enabled.count)")
            } catch {
                onStatus("Не удалось подготовить язык «\(SpeechLang.name(id))»: \(error.localizedDescription)")
            }
        }
    }
}

/// Полностью независимая обработка одного участника: свой Task, своя очередь, свои модели.
/// Любой вызов в SpeechAnalyzer защищён таймаутом в 5 секунд — если модель зависла и не может
/// разобрать слово, эта попытка бросается и дорожка тут же освобождается для следующей реплики.
@available(iOS 26.0, *)
private final class UserPipeline {
    private enum Command {
        case audio([Float])
        case end
        case shutdown
    }

    private let userId: String
    private let enabledLocales: [String]
    private let ready: ReadyLocales
    private let gate: AnalyzerGate
    private let sourceFormat: AVAudioFormat
    private let onUpdate: (VoiceTranscriber.Update) -> Void
    private let onStatus: (String) -> Void
    private let continuation: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    private let maxProbe = 2
    private static let stepTimeout = 5.0

    // Состояние трогает только worker Task этого участника — конкурентного доступа тут нет.
    private var knownLocale: String?
    private var active: LiveSession?
    private var probes: [String: LiveSession] = [:]
    private var probeSamples = 0
    private var round = 0
    private var recentOrder: [String] = []

    init(userId: String, enabledLocales: [String], ready: ReadyLocales, gate: AnalyzerGate,
         sourceFormat: AVAudioFormat, onUpdate: @escaping (VoiceTranscriber.Update) -> Void,
         onStatus: @escaping (String) -> Void) {
        self.userId = userId
        self.enabledLocales = enabledLocales
        self.ready = ready
        self.gate = gate
        self.sourceFormat = sourceFormat
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        let (stream, cont) = AsyncStream<Command>.makeStream()
        self.continuation = cont
        self.worker = Task { [weak self] in
            for await cmd in stream {
                guard let self else { return }
                await self.handle(cmd)
                if case .shutdown = cmd { return }
            }
        }
    }

    func enqueueAudio(_ mono: [Float]) { continuation.yield(.audio(mono)) }
    func enqueueEnd() { continuation.yield(.end) }
    func shutdown() {
        continuation.yield(.shutdown)
        continuation.finish()
    }

    private func handle(_ cmd: Command) async {
        switch cmd {
        case .audio(let samples):
            await handleAudio(samples)
        case .end:
            await finishUtterance()
        case .shutdown:
            await finishUtterance()
            discard(Array(probes.values))
            probes = [:]
        }
    }

    private func handleAudio(_ samples: [Float]) async {
        if active == nil && probes.isEmpty {
            await startUtterance()
        }
        if let a = active {
            a.feed(samples)
            return
        }
        guard !probes.isEmpty else { return }
        for s in probes.values { s.feed(samples) }
        probeSamples += samples.count
        await evaluateProbes(final: false)
    }

    /// Начало реплики: если язык говорящего уже известен — одна модель, иначе пробуем сразу
    /// несколько (не больше maxProbe, чтобы не перегружать телефон) и выбираем лучшую.
    private func startUtterance() async {
        let ids = await ready.ids
        guard !ids.isEmpty else { return }

        if let known = knownLocale, ids.contains(known) {
            active = await makeSession(known, emitting: true)
            return
        }
        if ids.count == 1, let only = ids.first {
            knownLocale = only
            active = await makeSession(only, emitting: true)
            return
        }

        var order = recentOrder.filter { ids.contains($0) }
        for id in enabledLocales where ids.contains(id) && !order.contains(id) { order.append(id) }
        let start = (round * maxProbe) % max(1, order.count)
        var candidates = Array(order.dropFirst(start).prefix(maxProbe))
        if candidates.isEmpty { candidates = Array(order.prefix(maxProbe)) }

        probeSamples = 0
        for id in candidates {
            if let s = await makeSession(id, emitting: false) {
                probes[id] = s
            }
        }
    }

    private func evaluateProbes(final: Bool) async {
        let seconds = Double(probeSamples) / 48000
        guard final || seconds >= 1.6 else { return }

        var best: (id: String, score: Double)?
        for (id, s) in probes {
            let sc = SpeechLang.score(s.currentText, locale: id)
            if best == nil || sc > best!.score { best = (id, sc) }
        }
        guard let best else { return }

        let confident = best.score >= 2.2
        guard confident || seconds >= 4.5 || final else { return }

        if best.score > 0.4, let winner = probes.removeValue(forKey: best.id) {
            discard(Array(probes.values))
            probes = [:]
            knownLocale = best.id
            recentOrder.removeAll { $0 == best.id }
            recentOrder.insert(best.id, at: 0)
            winner.emitting = true
            winner.emitNow()
            active = winner
        } else {
            discard(Array(probes.values))
            probes = [:]
            round += 1
        }
    }

    private func discard(_ sessions: [LiveSession]) {
        for s in sessions {
            let gate = self.gate
            Task {
                await s.finish(emit: false, timeout: UserPipeline.stepTimeout)
                await gate.release()
            }
        }
    }

    private func finishUtterance() async {
        if active == nil, !probes.isEmpty {
            await evaluateProbes(final: true)
        }
        if let a = active {
            await a.finish(emit: true, timeout: UserPipeline.stepTimeout)
            await gate.release()
            let text = a.currentText
            if SpeechLang.words(text) >= 4, let known = knownLocale,
               SpeechLang.probability(text, locale: known) < 0.12 {
                knownLocale = nil
            }
            active = nil
        }
        discard(Array(probes.values))
        probes = [:]
        probeSamples = 0
    }

    private func makeSession(_ localeId: String, emitting: Bool) async -> LiveSession? {
        guard let locale = await ready.get(localeId) else { return nil }
        await gate.acquire()
        let created = await withTimeout(UserPipeline.stepTimeout) { [sourceFormat] () async throws -> LiveSession in
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw LabError.engine("нет подходящего аудиоформата")
            }
            guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw LabError.engine("не удалось подготовить конвертер")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputStream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputStream)
            return LiveSession(
                localeId: localeId,
                userId: "",
                transcriber: transcriber,
                analyzer: analyzer,
                builder: builder,
                sourceFormat: sourceFormat,
                targetFormat: format,
                converter: converter,
                emitting: emitting,
                onUpdate: { _ in }
            )
        }
        guard let created else {
            await gate.release()
            onStatus("Модель для \(SpeechLang.name(localeId)) не запустилась вовремя — пробую позже")
            return nil
        }
        // userId/onUpdate нельзя захватить в @Sendable-замыкании выше без сложностей — доопределяем здесь.
        created.bind(userId: userId, onUpdate: onUpdate)
        return created
    }
}

/// Одна непрерывная реплика одного участника на одном языке.
/// `@unchecked Sendable`: создаётся и используется только из одного worker Task на участника
/// (плюс свой собственный resultsTask, который трогает только finalized/volatile этого же объекта);
/// нужен, чтобы можно было создать сессию под общим таймаутом (пересекает границу TaskGroup).
@available(iOS 26.0, *)
private final class LiveSession: @unchecked Sendable {
    let localeId: String
    private(set) var userId: String
    let analyzer: SpeechAnalyzer
    let builder: AsyncStream<AnalyzerInput>.Continuation
    let sourceFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    let converter: AVAudioConverter
    private var onUpdate: (VoiceTranscriber.Update) -> Void
    var resultsTask: Task<Void, Never>?
    var finalized: [String] = []
    var volatile = ""
    var emitting: Bool

    var currentText: String {
        var parts = finalized
        if !volatile.isEmpty { parts.append(volatile) }
        return parts.joined(separator: " ")
    }

    init(localeId: String, userId: String, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer,
         builder: AsyncStream<AnalyzerInput>.Continuation, sourceFormat: AVAudioFormat,
         targetFormat: AVAudioFormat, converter: AVAudioConverter, emitting: Bool,
         onUpdate: @escaping (VoiceTranscriber.Update) -> Void) {
        self.localeId = localeId
        self.userId = userId
        self.analyzer = analyzer
        self.builder = builder
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.emitting = emitting
        self.onUpdate = onUpdate
        self.resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.apply(text: text, isFinal: result.isFinal)
                }
            } catch {
                // Поток результатов оборвался с ошибкой: оставляем то, что успели распознать.
            }
        }
    }

    /// Привязка настоящего userId/onUpdate после создания (см. makeSession — объект собирается
    /// внутри @Sendable-замыкания, где userId ещё недоступен напрямую).
    func bind(userId: String, onUpdate: @escaping (VoiceTranscriber.Update) -> Void) {
        self.userId = userId
        self.onUpdate = onUpdate
    }

    private func apply(text: String, isFinal: Bool) {
        if isFinal {
            if !text.isEmpty { finalized.append(text) }
            volatile = ""
        } else {
            volatile = text
        }
        emit(final: false)
    }

    func emitNow() { emit(final: false) }

    private func emit(final: Bool) {
        guard emitting else { return }
        let text = currentText
        if !text.isEmpty {
            onUpdate(VoiceTranscriber.Update(userId: userId, text: text, isFinal: final, lang: localeId))
        }
    }

    func feed(_ samples: [Float]) {
        let n = samples.count
        guard n > 0,
              let src = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(n)),
              let ch = src.floatChannelData else { return }
        src.frameLength = AVAudioFrameCount(n)
        let dst = ch[0]
        for i in 0..<n { dst[i] = samples[i] }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(n) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var provided = false
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return src
        }
        if status != .error, out.frameLength > 0 {
            builder.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Завершить: `emit` = показать итоговый текст, иначе просто выбросить (проигравший вариант языка).
    /// Каждый шаг ограничен таймаутом — если модель зависла, бросаем попытку и не ждём её вечно.
    func finish(emit doEmit: Bool, timeout: Double) async {
        if !doEmit { emitting = false }
        builder.finish()

        let finalizeOk = await withTimeout(timeout) { [analyzer] in
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        if finalizeOk == nil {
            // Не уложились в таймаут: не ждём эту модель дальше, бросаем как есть.
            resultsTask?.cancel()
        } else {
            _ = await withTimeout(timeout) { [resultsTask] in
                await resultsTask?.value
            }
            resultsTask?.cancel()
        }
        if doEmit { emit(final: true) }
    }
}

#endif

// MARK: - Запасной вариант: SFSpeechRecognizer (один язык)

final class LegacyBackend: TranscribeBackend {
    private let onUpdate: (VoiceTranscriber.Update) -> Void
    private let onStatus: (String) -> Void
    private let localeId: String
    private let queue = DispatchQueue(label: "voice.transcriber.legacy")
    private var recognizer: SFSpeechRecognizer?
    private var sessions: [String: Session] = [:]
    private let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    private final class Session {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var lastText = ""
        var committed = false
        var ended = false
    }

    init(localeId: String, onUpdate: @escaping (VoiceTranscriber.Update) -> Void, onStatus: @escaping (String) -> Void) {
        self.localeId = localeId
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        let r = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        recognizer = r
        if let r, r.isAvailable {
            onStatus(r.supportsOnDeviceRecognition
                     ? "Распознавание речи (\(localeId)): на устройстве"
                     : "Распознавание речи (\(localeId)): через серверы Apple")
        } else {
            onStatus("Распознавание для \(localeId) недоступно")
        }
    }

    func append(userId: String, mono: [Float]) {
        queue.async {
            guard let recognizer = self.recognizer, recognizer.isAvailable, !mono.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.monoFormat, frameCapacity: AVAudioFrameCount(mono.count)),
                  let data = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(mono.count)
            let out = data[0]
            for i in 0..<mono.count { out[i] = mono[i] }
            let session = self.session(for: userId, recognizer: recognizer)
            session.request.append(buffer)
        }
    }

    func endUtterance(userId: String) {
        queue.async {
            if let s = self.sessions[userId], !s.ended {
                s.request.endAudio()
                s.ended = true
            }
        }
    }

    func endAll() {
        queue.async {
            for s in self.sessions.values where !s.ended {
                s.request.endAudio()
                s.ended = true
            }
        }
    }

    func shutdown() {
        queue.async {
            for s in self.sessions.values {
                s.request.endAudio()
                s.task?.cancel()
            }
            self.sessions = [:]
        }
    }

    private func session(for userId: String, recognizer: SFSpeechRecognizer) -> Session {
        if let s = sessions[userId], !s.ended { return s }
        let s = Session()
        s.request.shouldReportPartialResults = true
        s.request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            s.request.requiresOnDeviceRecognition = true
        }
        s.task = recognizer.recognitionTask(with: s.request) { [weak self, weak s] result, error in
            guard let self, let s else { return }
            self.queue.async {
                self.handle(userId: userId, session: s, result: result, error: error)
            }
        }
        sessions[userId] = s
        return s
    }

    private func handle(userId: String, session: Session, result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                session.lastText = text
                onUpdate(VoiceTranscriber.Update(userId: userId, text: text, isFinal: result.isFinal, lang: localeId))
                if result.isFinal { session.committed = true }
            }
            if result.isFinal { finish(userId, session) }
        }
        if error != nil {
            // Ошибка «речь не распознана» не должна стирать уже показанный текст: фиксируем последнее.
            if !session.committed, !session.lastText.isEmpty {
                onUpdate(VoiceTranscriber.Update(userId: userId, text: session.lastText, isFinal: true, lang: localeId))
                session.committed = true
            }
            finish(userId, session)
        }
    }

    private func finish(_ userId: String, _ session: Session) {
        session.ended = true
        if sessions[userId] === session { sessions[userId] = nil }
    }
}

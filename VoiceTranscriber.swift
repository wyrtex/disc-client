import Foundation
import Speech
import AVFoundation

/// Общий интерфейс распознавания. Аудио приходит моно, 48 кГц.
protocol TranscribeBackend: AnyObject {
    func append(userId: String, mono: [Float])
    func endUtterance(userId: String)
    func endAll()
    func shutdown()
}

/// Субтитры голоса. Для каждого участника своя сессия распознавания.
/// iOS 26+: новый SpeechAnalyzer (быстрые черновые результаты, длинная речь без обрывов).
/// Раньше: Apple Speech (SFSpeechRecognizer).
/// Язык выбирается вручную.
final class VoiceTranscriber {
    struct Update {
        let userId: String
        let text: String
        let isFinal: Bool
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

    func configure(enabled: Bool, locale: String) {
        queue.async {
            self.backend?.shutdown()
            self.backend = nil
            self.streams = [:]
            self.enabled = enabled
            guard enabled else {
                self.stopTimer()
                return
            }
            self.backend = self.makeBackend(locale: locale)
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

    private func makeBackend(locale: String) -> TranscribeBackend? {
        let update: (Update) -> Void = { [weak self] u in self?.onUpdate?(u) }
        let status: (String) -> Void = { [weak self] s in self?.onStatus?(s) }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return AnalyzerBackend(localeId: locale, onUpdate: update, onStatus: status)
        }
        #endif
        return LegacyBackend(localeId: locale, onUpdate: update, onStatus: status)
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

// MARK: - iOS 26: SpeechAnalyzer

#if compiler(>=6.2)

@available(iOS 26.0, *)
final class AnalyzerBackend: TranscribeBackend {
    private enum Command {
        case audio(String, [Float])
        case end(String)
        case endAll
        case shutdown
    }

    private let localeId: String
    private let onUpdate: (VoiceTranscriber.Update) -> Void
    private let onStatus: (String) -> Void
    private let continuation: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?

    // Состояние трогает только рабочая задача (команды выполняются по очереди).
    private var sessions: [String: LiveSession] = [:]
    private var locale: Locale?
    private var assetsReady = false
    private var unsupported = false
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    init(localeId: String, onUpdate: @escaping (VoiceTranscriber.Update) -> Void, onStatus: @escaping (String) -> Void) {
        self.localeId = localeId
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

    func append(userId: String, mono: [Float]) { continuation.yield(.audio(userId, mono)) }
    func endUtterance(userId: String) { continuation.yield(.end(userId)) }
    func endAll() { continuation.yield(.endAll) }
    func shutdown() {
        continuation.yield(.shutdown)
        continuation.finish()
    }

    private func handle(_ cmd: Command) async {
        switch cmd {
        case .audio(let uid, let samples):
            guard !unsupported else { return }
            if let s = await session(for: uid) { s.feed(samples) }
        case .end(let uid):
            if let s = sessions.removeValue(forKey: uid) { await s.finish() }
        case .endAll, .shutdown:
            let all = sessions
            sessions = [:]
            for s in all.values { await s.finish() }
        }
    }

    private func session(for uid: String) async -> LiveSession? {
        if let s = sessions[uid] { return s }
        do {
            if locale == nil {
                let requested = Locale(identifier: localeId)
                guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                    unsupported = true
                    onStatus("Язык \(localeId) не поддерживается распознаванием")
                    return nil
                }
                locale = supported
            }
            guard let locale else { return nil }

            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            if !assetsReady {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    onStatus("Скачиваю модель распознавания речи…")
                    try await request.downloadAndInstall()
                }
                assetsReady = true
                onStatus("Распознавание речи (\(localeId)): на устройстве")
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                onStatus("Нет подходящего аудиоформата для распознавания")
                return nil
            }
            guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                onStatus("Не удалось подготовить аудио для распознавания")
                return nil
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputStream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputStream)

            let s = LiveSession(
                userId: uid,
                transcriber: transcriber,
                analyzer: analyzer,
                builder: builder,
                sourceFormat: sourceFormat,
                targetFormat: format,
                converter: converter,
                onUpdate: onUpdate
            )
            sessions[uid] = s
            return s
        } catch {
            onStatus("Ошибка распознавания: \(error.localizedDescription)")
            return nil
        }
    }

    /// Одна непрерывная реплика одного участника.
    private final class LiveSession {
        let userId: String
        let analyzer: SpeechAnalyzer
        let builder: AsyncStream<AnalyzerInput>.Continuation
        let sourceFormat: AVAudioFormat
        let targetFormat: AVAudioFormat
        let converter: AVAudioConverter
        let onUpdate: (VoiceTranscriber.Update) -> Void
        var resultsTask: Task<Void, Never>?
        var finalized: [String] = []
        var volatile = ""

        init(userId: String, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer,
             builder: AsyncStream<AnalyzerInput>.Continuation, sourceFormat: AVAudioFormat,
             targetFormat: AVAudioFormat, converter: AVAudioConverter,
             onUpdate: @escaping (VoiceTranscriber.Update) -> Void) {
            self.userId = userId
            self.analyzer = analyzer
            self.builder = builder
            self.sourceFormat = sourceFormat
            self.targetFormat = targetFormat
            self.converter = converter
            self.onUpdate = onUpdate
            self.resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        self.apply(text: text, isFinal: result.isFinal)
                    }
                } catch {
                    // Поток результатов завершился ошибкой: оставляем то, что успели распознать.
                }
            }
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

        private func emit(final: Bool) {
            var parts = finalized
            if !volatile.isEmpty { parts.append(volatile) }
            let text = parts.joined(separator: " ")
            if !text.isEmpty {
                onUpdate(VoiceTranscriber.Update(userId: userId, text: text, isFinal: final))
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

        func finish() async {
            builder.finish()
            // Страховка: если поток результатов не закрылся, через 3 секунды обрываем ожидание.
            let watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.resultsTask?.cancel()
            }
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
            watchdog.cancel()
            emit(final: true)
        }
    }
}

#endif

// MARK: - Запасной вариант: SFSpeechRecognizer

final class LegacyBackend: TranscribeBackend {
    private let onUpdate: (VoiceTranscriber.Update) -> Void
    private let onStatus: (String) -> Void
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
                onUpdate(VoiceTranscriber.Update(userId: userId, text: text, isFinal: result.isFinal))
                if result.isFinal { session.committed = true }
            }
            if result.isFinal { finish(userId, session) }
        }
        if error != nil {
            // Ошибка «речь не распознана» не должна стирать уже показанный текст: фиксируем последнее.
            if !session.committed, !session.lastText.isEmpty {
                onUpdate(VoiceTranscriber.Update(userId: userId, text: session.lastText, isFinal: true))
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

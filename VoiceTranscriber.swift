import Foundation
import Speech
import AVFoundation

/// Распознавание речи участников: для каждого говорящего своя сессия Apple Speech.
/// Язык выбирается вручную (Speech не умеет определять язык сам).
final class VoiceTranscriber {
    struct Update {
        let userId: String
        let text: String
        let isFinal: Bool
    }

    var onUpdate: ((Update) -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "voice.transcriber")
    private var recognizer: SFSpeechRecognizer?
    private var enabled = false
    private var sessions: [String: Session] = [:]
    private var timer: DispatchSourceTimer?
    private let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    private final class Session {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var lastFeed = Date()
        var ended = false
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
            self.endAll()
            self.enabled = enabled
            guard enabled else {
                self.stopTimer()
                return
            }
            let r = SFSpeechRecognizer(locale: Locale(identifier: locale))
            self.recognizer = r
            if let r, r.isAvailable {
                let mode = r.supportsOnDeviceRecognition ? "на устройстве" : "через серверы Apple"
                self.onStatus?("Распознавание речи (\(locale)): \(mode)")
            } else {
                self.onStatus?("Распознавание для \(locale) недоступно")
            }
            self.startTimer()
        }
    }

    func reset() {
        queue.async { self.endAll() }
    }

    /// Аудио от участника (вызывается из медиа-потока). Стерео или моно, 48 кГц.
    func feed(userId: String, interleaved: [Float], channels: Int, frames: Int) {
        queue.async {
            guard self.enabled, let recognizer = self.recognizer, recognizer.isAvailable,
                  frames > 0, interleaved.count >= frames * channels,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.monoFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let out = data[0]
            if channels == 2 {
                for i in 0..<frames {
                    out[i] = (interleaved[2 * i] + interleaved[2 * i + 1]) * 0.5
                }
            } else {
                for i in 0..<frames { out[i] = interleaved[i] }
            }
            let session = self.session(for: userId, recognizer: recognizer)
            session.request.append(buffer)
            session.lastFeed = Date()
        }
    }

    // MARK: Внутреннее

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
                onUpdate?(Update(userId: userId, text: text, isFinal: result.isFinal))
            }
            if result.isFinal { finish(userId, session) }
        }
        if error != nil { finish(userId, session) }
    }

    private func finish(_ userId: String, _ session: Session) {
        session.ended = true
        if sessions[userId] === session { sessions[userId] = nil }
    }

    private func endAll() {
        for s in sessions.values {
            s.request.endAudio()
            s.task?.cancel()
        }
        sessions = [:]
    }

    private func startTimer() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.4, repeating: 0.4)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for s in self.sessions.values where !s.ended && now.timeIntervalSince(s.lastFeed) > 1.0 {
                s.request.endAudio()
                s.ended = true
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

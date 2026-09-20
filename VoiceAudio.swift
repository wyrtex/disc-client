import Foundation
import AVFoundation

enum VoiceAudioError: Error {
    case noInput
}

/// Линейный ресемплер для микрофона (когда железо даёт не 48 кГц).
struct LinearResampler {
    private var pos: Double = 0
    private var prev: Float = 0

    mutating func process(_ input: [Float], from src: Double, to dst: Double) -> [Float] {
        guard !input.isEmpty, src > 0, dst > 0 else { return [] }
        let step = src / dst
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        while true {
            let i = Int(pos.rounded(.down))
            if i + 1 > input.count { break }
            let frac = Float(pos - Double(i))
            let a: Float = (i == 0) ? prev : input[i - 1]
            let b: Float = input[i]
            out.append(a + (b - a) * frac)
            pos += step
        }
        pos -= Double(input.count)
        prev = input[input.count - 1]
        return out
    }
}

/// Аудиодвижок голоса: воспроизведение участников, захват микрофона, эхоподавление, маршрут вывода.
final class VoiceAudio {
    private var engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private let lock = NSLock()
    private let micQueue = DispatchQueue(label: "voice.mic")
    private var observers: [NSObjectProtocol] = []
    private var resampler = LinearResampler()
    private var accumulator: [Float] = []
    private var running = false
    private var deafened = false

    private final class PlayerChannel {
        let node = AVAudioPlayerNode()
        var pending = 0
    }
    private var channels: [UInt32: PlayerChannel] = [:]

    var speakerOn = true
    private(set) var micRunning = false
    private(set) var echoCancellation = false

    /// Кадр микрофона: 960 сэмплов, mono, 48 кГц (20 мс).
    var onMicFrame: (([Float]) -> Void)?
    var log: ((String) -> Void)?

    // MARK: Разрешения и маршруты

    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }

    static func setSpeaker(_ on: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    static func currentOutputName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "—"
    }

    struct InputDevice: Identifiable {
        let id: String
        let name: String
        let selected: Bool
    }

    static func inputDevices() -> [InputDevice] {
        let s = AVAudioSession.sharedInstance()
        let current = s.currentRoute.inputs.first?.uid
        return (s.availableInputs ?? []).map {
            InputDevice(id: $0.uid, name: $0.portName, selected: $0.uid == current)
        }
    }

    static func selectInput(uid: String) {
        let s = AVAudioSession.sharedInstance()
        if let port = s.availableInputs?.first(where: { $0.uid == uid }) {
            try? s.setPreferredInput(port)
        }
    }

    // MARK: Запуск и остановка

    func start(useMic: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if running { return }

        if useMic {
            if boot(voiceChat: true, mic: true, voiceProcessing: true) {
                finishStart()
                return
            }
            log?("Аудио: эхоподавление недоступно, пробую без него")
            if boot(voiceChat: false, mic: true, voiceProcessing: false) {
                finishStart()
                return
            }
            log?("Аудио: микрофон недоступен, только прослушивание")
        }
        if boot(voiceChat: false, mic: false, voiceProcessing: false) {
            finishStart()
        } else {
            log?("Аудио: не удалось запустить вывод")
        }
    }

    private func boot(voiceChat: Bool, mic: Bool, voiceProcessing: Bool) -> Bool {
        teardownEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: voiceChat ? .voiceChat : .default,
                options: [.allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)

            let e = AVAudioEngine()
            if mic {
                let input = e.inputNode
                if voiceProcessing { try input.setVoiceProcessingEnabled(true) }
                let f = input.outputFormat(forBus: 0)
                guard f.sampleRate > 0, f.channelCount > 0 else { throw VoiceAudioError.noInput }
                input.installTap(onBus: 0, bufferSize: 1024, format: f) { [weak self] buffer, _ in
                    self?.handleMic(buffer)
                }
            }
            _ = e.mainMixerNode
            e.prepare()
            try e.start()

            engine = e
            micRunning = mic
            echoCancellation = mic && voiceProcessing
            return true
        } catch {
            log?("Аудио: ошибка запуска (\(error.localizedDescription))")
            return false
        }
    }

    private func finishStart() {
        running = true
        VoiceAudio.setSpeaker(speakerOn)
        engine.mainMixerNode.outputVolume = deafened ? 0 : 1
        log?("Аудио: запущено. Микрофон: \(micRunning ? "да" : "нет"), эхоподавление: \(echoCancellation ? "да" : "нет"), вывод: \(VoiceAudio.currentOutputName())")

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartIfNeeded()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restartIfNeeded()
        })
    }

    private func restartIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        VoiceAudio.setSpeaker(speakerOn)
    }

    private func teardownEngine() {
        for c in channels.values { c.node.stop() }
        channels = [:]
        if micRunning { engine.inputNode.removeTap(onBus: 0) }
        if engine.isRunning { engine.stop() }
        micRunning = false
        echoCancellation = false
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardownEngine()
        running = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        micQueue.async { self.accumulator = [] }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setDeafened(_ d: Bool) {
        lock.lock()
        defer { lock.unlock() }
        deafened = d
        if running { engine.mainMixerNode.outputVolume = d ? 0 : 1 }
    }

    // MARK: Микрофон

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let sampleRate = buffer.format.sampleRate
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        micQueue.async { [weak self] in
            self?.processMic(samples, sampleRate: sampleRate)
        }
    }

    private func processMic(_ input: [Float], sampleRate: Double) {
        let converted = (sampleRate == 48000) ? input : resampler.process(input, from: sampleRate, to: 48000)
        accumulator.append(contentsOf: converted)
        while accumulator.count >= 960 {
            let frame = Array(accumulator.prefix(960))
            accumulator.removeFirst(960)
            onMicFrame?(frame)
        }
    }

    // MARK: Воспроизведение

    func play(ssrc: UInt32, interleaved: [Float], frames: Int) {
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = data[0]
        let right = data[1]
        for i in 0..<frames {
            left[i] = interleaved[2 * i]
            right[i] = interleaved[2 * i + 1]
        }

        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        let ch: PlayerChannel
        if let existing = channels[ssrc] {
            ch = existing
        } else {
            let c = PlayerChannel()
            channels[ssrc] = c
            engine.attach(c.node)
            engine.connect(c.node, to: engine.mainMixerNode, format: format)
            ch = c
        }
        if ch.pending > 25 {
            // Очередь разрослась: пропускаем, чтобы не копить задержку.
            lock.unlock()
            return
        }
        ch.pending += 1
        let pendingNow = ch.pending
        let isRunning = engine.isRunning
        lock.unlock()

        ch.node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak ch] _ in
            guard let self, let ch else { return }
            self.lock.lock()
            ch.pending -= 1
            self.lock.unlock()
        }
        if !ch.node.isPlaying && pendingNow >= 3 && isRunning {
            ch.node.play()
        }
    }
}

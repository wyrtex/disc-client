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
///
/// Запуск и остановка идут в отдельной очереди и никогда не блокируют главный поток.
/// Блокировка состояния не удерживается во время остановки движка: колбэки плееров берут только `pendingLock`.
final class VoiceAudio {
    private let control = DispatchQueue(label: "voice.audio.control")
    private let stateLock = NSLock()
    private let pendingLock = NSLock()
    private let micQueue = DispatchQueue(label: "voice.mic")

    private var engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private var observers: [NSObjectProtocol] = []
    private var resampler = LinearResampler()
    private var accumulator: [Float] = []
    private var running = false
    private var deafened = false
    private var micRunning = false
    private var echoCancellation = false

    private final class PlayerChannel {
        let node = AVAudioPlayerNode()
        var pending = 0
    }
    private var channels: [UInt32: PlayerChannel] = [:]

    var speakerOn = true

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

    // MARK: Запуск и остановка (в отдельной очереди)

    func start(useMic: Bool) {
        control.async { self.startSync(useMic: useMic) }
    }

    func stop() {
        control.async { self.stopSync() }
    }

    private func startSync(useMic: Bool) {
        stateLock.lock()
        let already = running
        stateLock.unlock()
        if already { return }

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
        teardown()
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

            stateLock.lock()
            engine = e
            micRunning = mic
            echoCancellation = mic && voiceProcessing
            stateLock.unlock()
            return true
        } catch {
            log?("Аудио: ошибка запуска (\(error.localizedDescription))")
            return false
        }
    }

    private func finishStart() {
        stateLock.lock()
        running = true
        engine.mainMixerNode.outputVolume = deafened ? 0 : 1
        let mic = micRunning
        let echo = echoCancellation
        stateLock.unlock()

        VoiceAudio.setSpeaker(speakerOn)
        log?("Аудио: запущено. Микрофон: \(mic ? "да" : "нет"), эхоподавление: \(echo ? "да" : "нет"), вывод: \(VoiceAudio.currentOutputName())")

        let center = NotificationCenter.default
        let obsConfig = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.control.async { self?.restartIfNeeded() }
        }
        let obsInterrupt = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.control.async { self?.restartIfNeeded() }
        }
        stateLock.lock()
        observers = [obsConfig, obsInterrupt]
        stateLock.unlock()
    }

    private func restartIfNeeded() {
        stateLock.lock()
        let isRunning = running
        let e = engine
        stateLock.unlock()
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !e.isRunning { try? e.start() }
        VoiceAudio.setSpeaker(speakerOn)
    }

    /// Забирает состояние под замком, а останавливает уже без замка.
    private func teardown() {
        stateLock.lock()
        let oldEngine = engine
        let oldChannels = channels
        let hadMic = micRunning
        let oldObservers = observers
        channels = [:]
        observers = []
        running = false
        micRunning = false
        echoCancellation = false
        stateLock.unlock()

        for o in oldObservers { NotificationCenter.default.removeObserver(o) }
        for c in oldChannels.values { c.node.stop() }
        if hadMic { oldEngine.inputNode.removeTap(onBus: 0) }
        if oldEngine.isRunning { oldEngine.stop() }
    }

    private func stopSync() {
        teardown()
        micQueue.async { self.accumulator = [] }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setDeafened(_ d: Bool) {
        stateLock.lock()
        deafened = d
        if running { engine.mainMixerNode.outputVolume = d ? 0 : 1 }
        stateLock.unlock()
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

        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, engine.isRunning else { return }

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

        pendingLock.lock()
        if ch.pending > 25 {
            // Очередь разрослась: пропускаем, чтобы не копить задержку.
            pendingLock.unlock()
            return
        }
        ch.pending += 1
        let pendingNow = ch.pending
        pendingLock.unlock()

        ch.node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak ch] _ in
            guard let self, let ch else { return }
            self.pendingLock.lock()
            ch.pending -= 1
            self.pendingLock.unlock()
        }
        if !ch.node.isPlaying && pendingNow >= 3 {
            ch.node.play()
        }
    }
}

import AVFoundation

/// Единая точка управления аудиосессией с приоритетами. Главное правило: мы НИКОГДА не глушим
/// музыку пользователя без необходимости — везде используется подмешивание (.mixWithOthers).
/// - `.mixing` (простой): музыка играет, немой инлайн-контент (гифки) подмешивается.
/// - `.playback`: видео/голосовые со звуком — тоже подмешиваются к музыке.
/// - `.voice` (войс): .playAndRecord + mix, звук других приложений не выкидывает из войса.
/// Плюс фоновый keepalive: тихий зацикленный звук (громкость 0, подмешивание) держит приложение
/// живым в фоне — чтобы presence/активность показывались, даже когда приложение свёрнуто.
enum AudioHub {
    enum Mode { case mixing, playback, voice }
    private(set) static var mode: Mode = .mixing
    private static var keepAliveOn = false
    private static var silent: AVAudioPlayer?

    static var inVoice: Bool { mode == .voice }

    static func enterVoice() { mode = .voice }
    static func exitVoice() { mode = .mixing; applyMixing() }
    static func ensureMixing() { guard mode == .mixing else { return }; applyMixing() }

    static func beginPlayback() {
        guard mode != .voice else { return }
        mode = .playback
        apply(.playback, [.mixWithOthers])
    }
    static func endPlayback() {
        guard mode == .playback else { return }
        mode = .mixing
        applyMixing()
    }

    /// Фоновый keepalive: тихий звук держит сокет живым, когда приложение свёрнуто.
    static func setKeepAlive(_ on: Bool) {
        guard keepAliveOn != on else { return }
        keepAliveOn = on
        if on { startSilent() } else { stopSilent() }
        if mode == .mixing { applyMixing() }
    }

    // MARK: Внутреннее

    private static func applyMixing() {
        // С keepalive держим фоновую .playback (iOS не усыпляет звук), иначе лёгкий .ambient.
        if keepAliveOn { apply(.playback, [.mixWithOthers]) }
        else { apply(.ambient, [.mixWithOthers]) }
    }

    private static func apply(_ cat: AVAudioSession.Category, _ opts: AVAudioSession.CategoryOptions, mode m: AVAudioSession.Mode = .default) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(cat, mode: m, options: opts)
        try? s.setActive(true)
    }

    private static func startSilent() {
        guard silent == nil, let data = silentWav, let p = try? AVAudioPlayer(data: data) else { return }
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        p.play()
        silent = p
    }

    private static func stopSilent() {
        silent?.stop()
        silent = nil
    }

    /// 0.3 с тишины, WAV 8 кГц моно 16-бит — для фонового keepalive.
    private static let silentWav: Data? = {
        let sampleRate = 8000, seconds = 0.3
        let samples = Int(Double(sampleRate) * seconds)
        let dataBytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func u16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        d.append("RIFF".data(using: .ascii)!)
        d.append(u32(UInt32(36 + dataBytes)))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(u32(16))                 // размер fmt
        d.append(u16(1))                  // PCM
        d.append(u16(1))                  // моно
        d.append(u32(UInt32(sampleRate)))
        d.append(u32(UInt32(sampleRate * 2)))
        d.append(u16(2))                  // блок
        d.append(u16(16))                 // бит
        d.append("data".data(using: .ascii)!)
        d.append(u32(UInt32(dataBytes)))
        d.append(Data(count: dataBytes))  // тишина
        return d
    }()
}

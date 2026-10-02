import AVFoundation

/// Единая точка управления аудиосессией с приоритетами:
/// - `.mixing` (простой): музыка пользователя продолжает играть, немой инлайн-контент (гифки,
///   зацикленные видео) её НЕ паузит, звук наружу не забирается;
/// - `.playback`: полноэкранное видео и голосовые сообщения забирают вывод (паузят музыку),
///   а по завершении мы возвращаем фоновый режим и даём музыке продолжить;
/// - `.voice` (войс): держит .playAndRecord сам и имеет наивысший приоритет — остальные режимы
///   в это время сессию не трогают.
enum AudioHub {
    enum Mode { case mixing, playback, voice }
    private(set) static var mode: Mode = .mixing

    static var inVoice: Bool { mode == .voice }

    /// Войс взял сессию под себя (VoiceAudio сам ставит .playAndRecord).
    static func enterVoice() { mode = .voice }

    /// Войс завершён — возвращаем фоновый подмешивающий режим.
    static func exitVoice() {
        mode = .mixing
        applyMixing(active: true)
    }

    /// Фоновый режим: музыку не глушим, немой контент подмешивается. Не перебивает playback/voice.
    static func ensureMixing() {
        guard mode == .mixing else { return }
        applyMixing(active: true)
    }

    /// Начинаем воспроизведение СО ЗВУКОМ (видео/голосовое) — забираем вывод. В войсе не трогаем.
    static func beginPlayback() {
        guard mode != .voice else { return }
        mode = .playback
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
    }

    /// Закончили воспроизведение со звуком — отпускаем сессию, музыка пользователя может продолжить.
    static func endPlayback() {
        guard mode == .playback else { return }
        mode = .mixing
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? s.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }

    private static func applyMixing(active: Bool) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        if active { try? s.setActive(true) }
    }
}

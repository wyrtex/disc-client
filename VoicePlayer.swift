import AVFoundation
import SwiftUI
import SwiftOGG

/// Проигрывание голосовых сообщений: скачиваем OGG/Opus, конвертируем в m4a, играем.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    @Published var playingID: String?
    @Published var loadingID: String?
    @Published var progress: Double = 0
    @Published var errorID: String?
    @Published var errorText: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var cache: [String: URL] = [:]

    func toggle(_ a: Attachment) async {
        if playingID == a.id {
            stop()
            return
        }
        stop()
        errorID = nil
        errorText = nil
        loadingID = a.id
        defer { loadingID = nil }
        do {
            let file = try await localFile(a)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: file)
            p.delegate = self
            guard p.play() else { return }
            player = p
            playingID = a.id
            progress = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            errorID = a.id
            errorText = "Не удалось воспроизвести: " + error.localizedDescription
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
    }

    private func tick() {
        guard let p = player, p.duration > 0 else { return }
        progress = min(1, p.currentTime / p.duration)
    }

    private func localFile(_ a: Attachment) async throws -> URL {
        if let u = cache[a.id], FileManager.default.fileExists(atPath: u.path) { return u }
        guard let url = URL(string: a.url) else { throw URLError(.badURL) }
        let (data, _) = try await ImageLoader.shared.session.data(from: url)
        let tmp = FileManager.default.temporaryDirectory
        let ogg = tmp.appendingPathComponent("v-\(a.id).ogg")
        let m4a = tmp.appendingPathComponent("v-\(a.id).m4a")
        try data.write(to: ogg)
        try? FileManager.default.removeItem(at: m4a)
        try await Task.detached(priority: .userInitiated) {
            try OGGConverter.convertOpusOGGToM4aFile(src: ogg, dest: m4a)
        }.value
        try? FileManager.default.removeItem(at: ogg)
        cache[a.id] = m4a
        return m4a
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// Плашка голосового сообщения: play/pause, волна, длительность.
struct VoiceMessageView: View {
    let attachment: Attachment
    @ObservedObject private var player = VoicePlayer.shared

    private let barCount = 34

    private var isPlaying: Bool { player.playingID == attachment.id }
    private var isLoading: Bool { player.loadingID == attachment.id }

    private var durationText: String {
        let total = Int((attachment.duration_secs ?? 0).rounded())
        let shown = isPlaying ? max(0, total - Int(Double(total) * player.progress)) : total
        return String(format: "%d:%02d", shown / 60, shown % 60)
    }

    var body: some View {
        let bars = attachment.bars(barCount)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button {
                    Task { await player.toggle(attachment) }
                } label: {
                    ZStack {
                        Circle().fill(Theme.blurple)
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)

                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { i, h in
                        Capsule()
                            .fill(barColor(i))
                            .frame(width: 3, height: max(4, CGFloat(h) * 28))
                    }
                }
                .frame(height: 30)

                Text(durationText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            if player.errorID == attachment.id, let e = player.errorText {
                Text(e)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
            }
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func barColor(_ i: Int) -> Color {
        guard isPlaying else { return Theme.muted }
        return Double(i) / Double(barCount) < player.progress ? Theme.blurple : Theme.muted
    }
}

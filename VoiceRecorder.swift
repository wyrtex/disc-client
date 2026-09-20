import AVFoundation
import SwiftUI

struct RecordedVoice {
    let url: URL
    let duration: Double
    let waveformBase64: String
}

/// Запись голосового сообщения. Пишем AAC/m4a (mono, 48 кГц), в OGG/Opus конвертируем перед отправкой.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var levels: [Float] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var allLevels: [Float] = []
    private var fileURL: URL?

    func start() async -> Bool {
        let granted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        guard granted else { return false }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else { return false }

            recorder = rec
            fileURL = url
            allLevels = []
            levels = []
            elapsed = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            return true
        } catch {
            return false
        }
    }

    private func tick() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        let db = rec.averagePower(forChannel: 0)
        let v = max(0, min(1, (db + 50) / 50))
        allLevels.append(v)
        levels = Array(allLevels.suffix(36))
        elapsed = rec.currentTime
    }

    func stop() -> RecordedVoice? {
        guard let rec = recorder, let url = fileURL else { return nil }
        let duration = rec.currentTime
        rec.stop()
        let wave = waveformBase64()
        cleanup()
        return RecordedVoice(url: url, duration: duration, waveformBase64: wave)
    }

    func cancel() {
        guard recorder != nil else { return }
        recorder?.stop()
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        cleanup()
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        fileURL = nil
        isRecording = false
        elapsed = 0
        levels = []
    }

    /// До 256 значений 0...255, base64. Так Discord рисует волну голосового сообщения.
    private func waveformBase64() -> String {
        let total = allLevels.count
        let n = min(256, max(1, total))
        var bytes: [UInt8] = []
        for i in 0..<n {
            let start = min(i * total / n, max(total - 1, 0))
            let end = min(max(start + 1, (i + 1) * total / n), total)
            var avg: Float = 0
            if total > 0, start < end {
                let slice = allLevels[start..<end]
                avg = slice.reduce(0, +) / Float(slice.count)
            }
            bytes.append(UInt8(max(0, min(255, avg * 255))))
        }
        return Data(bytes).base64EncodedString()
    }
}

/// Живая волна во время записи.
struct LiveWaveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                Capsule()
                    .fill(Theme.blurple)
                    .frame(width: 3, height: max(4, CGFloat(v) * 24))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

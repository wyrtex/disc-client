import Foundation
import AVFoundation

/// Запись демонстрации в mp4 внутри расширения. Пишет ровно те кадры, что уходят на сервер
/// (после блюра), плюс звук приложения, если он включён. Файл кладётся в общую папку App Group,
/// приложение потом сохраняет его в галерею. Работает на CMSampleBuffer'ах от ReplayKit напрямую,
/// поэтому не тратит лишнюю память (важно из-за лимита 50 МБ у расширения).
final class StreamRecorder {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var sessionStarted = false
    private let queue = DispatchQueue(label: "stream.recorder")
    private(set) var outputURL: URL?

    var onError: ((String) -> Void)?

    /// Готовит файл. Размер задаём по фактическому первому видеокадру (в prepare заранее не знаем).
    func start(width: Int, height: Int, includeAudio: Bool) {
        queue.sync {
            guard !started else { return }
            guard let dir = BroadcastShared.defaults.flatMap({ _ in
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BroadcastShared.appGroup)
            }) else {
                onError?("Нет общей папки для записи")
                return
            }
            let url = dir.appendingPathComponent("stream-\(Int(Date().timeIntervalSince1970)).mp4")
            try? FileManager.default.removeItem(at: url)
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let vSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
                vInput.expectsMediaDataInRealTime = true
                if w.canAdd(vInput) { w.add(vInput) }
                videoInput = vInput

                if includeAudio {
                    let aSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: 2,
                        AVSampleRateKey: 44100,
                        AVEncoderBitRateKey: 128000
                    ]
                    let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                    aInput.expectsMediaDataInRealTime = true
                    if w.canAdd(aInput) { w.add(aInput) }
                    audioInput = aInput
                }

                writer = w
                outputURL = url
                started = true
            } catch {
                onError?("Не удалось начать запись: \(error.localizedDescription)")
            }
        }
    }

    /// Видеокадр из системы (несжатый CMSampleBuffer). Writer сам кодирует его в H264 —
    /// отдельно от нашего сетевого кодировщика, чтобы не мешать отправке.
    func appendVideo(_ sb: CMSampleBuffer) {
        queue.async {
            guard self.started, let w = self.writer, let input = self.videoInput else { return }
            if w.status == .unknown {
                w.startWriting()
                w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
                self.sessionStarted = true
            }
            guard w.status == .writing, input.isReadyForMoreMediaData, self.sessionStarted else { return }
            input.append(sb)
        }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        queue.async {
            guard self.started, self.sessionStarted, let input = self.audioInput,
                  self.writer?.status == .writing, input.isReadyForMoreMediaData else { return }
            input.append(sb)
        }
    }

    /// Завершает файл и отдаёт путь через onFinished.
    func finish(_ onFinished: @escaping (URL?) -> Void) {
        queue.async {
            guard self.started, let w = self.writer else { onFinished(nil); return }
            self.started = false
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let url = self.outputURL
            if w.status == .writing {
                w.finishWriting { onFinished(url) }
            } else {
                onFinished(nil)
            }
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
        }
    }
}

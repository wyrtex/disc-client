import SwiftUI
import AVFoundation
#if canImport(SherpaOnnxC)
import SherpaOnnxC
#endif

// MARK: - Файлы модели Pocket TTS (Kyutai, английская версия из sherpa-onnx)

enum PocketFiles {
    static let folder = "sherpa-onnx-pocket-tts-int8-2026-01-26"
    static let archive = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-pocket-tts-int8-2026-01-26.tar.bz2")!
    static let required = [
        "lm_flow.int8.onnx", "lm_main.int8.onnx", "encoder.onnx",
        "decoder.int8.onnx", "text_conditioner.onnx", "vocab.json", "token_scores.json"
    ]

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("pocket-tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    static var dir: URL { root.appendingPathComponent(folder, isDirectory: true) }

    static var isReady: Bool {
        required.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    static var sizeOnDisk: Int64 {
        var total: Int64 = 0
        for f in required {
            let path = dir.appendingPathComponent(f).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    static func referenceURL(_ slot: RefSlot) -> URL {
        root.appendingPathComponent("lab-ref-\(slot.rawValue).wav")
    }
}

enum RefSlot: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var title: String { self == .ru ? "По-русски" : "По-английски" }
}

enum LabError: LocalizedError {
    case libraryMissing
    case modelMissing
    case referenceMissing
    case engine(String)
    case archive(String)
    case download(String)

    var errorDescription: String? {
        switch self {
        case .libraryMissing: return "Библиотека sherpa-onnx не подключена к этой сборке."
        case .modelMissing: return "Модель не скачана."
        case .referenceMissing: return "Нет записи твоего голоса."
        case .engine(let s): return "Движок озвучки: \(s)"
        case .archive(let s): return "Распаковка: \(s)"
        case .download(let s): return "Скачивание: \(s)"
        }
    }
}

// MARK: - Скачивание

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    func download(_ url: URL, configuration: URLSessionConfiguration) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let cfg = configuration
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 3600
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            self.session = s
            s.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.bz2")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let c = continuation {
            c.resume(throwing: error)
            continuation = nil
            session.invalidateAndCancel()
        }
    }
}

// MARK: - Распаковка .tar.bz2

final class TarSink {
    private enum Mode {
        case header
        case body(Int)
        case pad(Int)
    }

    private let root: URL
    private var mode = Mode.header
    private var buffer = Data()
    private var handle: FileHandle?
    private var skipping = false
    private var entrySize = 0

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func feed(_ data: Data) throws {
        buffer.append(data)
        while true {
            switch mode {
            case .header:
                guard buffer.count >= 512 else { return }
                let header = Data(buffer.prefix(512))
                buffer.removeFirst(512)
                try startEntry(header)
            case .body(let remaining):
                if buffer.isEmpty { return }
                let n = min(remaining, buffer.count)
                if !skipping, let handle {
                    try handle.write(contentsOf: buffer.prefix(n))
                }
                buffer.removeFirst(n)
                if n == remaining {
                    try handle?.close()
                    handle = nil
                    skipping = false
                    let pad = (512 - entrySize % 512) % 512
                    mode = pad > 0 ? .pad(pad) : .header
                } else {
                    mode = .body(remaining - n)
                }
            case .pad(let remaining):
                if buffer.isEmpty { return }
                let n = min(remaining, buffer.count)
                buffer.removeFirst(n)
                mode = n == remaining ? .header : .pad(remaining - n)
            }
        }
    }

    private func string(_ h: Data, _ range: Range<Int>) -> String {
        let bytes = h[range].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func startEntry(_ h: Data) throws {
        if h.allSatisfy({ $0 == 0 }) {
            mode = .header
            return
        }
        var name = string(h, 0..<100)
        if string(h, 257..<262) == "ustar" {
            let prefix = string(h, 345..<500)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        let sizeText = string(h, 124..<136).trimmingCharacters(in: .whitespaces)
        let size = Int(sizeText, radix: 8) ?? 0
        let type = h[156]
        entrySize = size

        let base = (name as NSString).lastPathComponent
        let isRegular = type == 0x30 || type == 0
        let unwanted = name.contains("test_wavs") || base.hasPrefix("._")

        if type == 0x35 {
            // Папка
            let url = root.appendingPathComponent(name).standardizedFileURL
            if url.path.hasPrefix(root.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            mode = .header
            return
        }

        if isRegular && !unwanted {
            let url = root.appendingPathComponent(name).standardizedFileURL
            guard url.path.hasPrefix(root.path) else { throw LabError.archive("небезопасный путь") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            skipping = false
        } else {
            skipping = true
        }
        mode = size > 0 ? .body(size) : .header
        if size == 0 {
            try handle?.close()
            handle = nil
            skipping = false
        }
    }
}

enum ArchiveTools {
    /// Потоковая распаковка bzip2 + tar, чтобы не держать 200 МБ в памяти.
    static func extractTarBz2(archive: URL, to root: URL, progress: @escaping (Double) -> Void) throws {
        let total = ((try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? Int) ?? 1
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }

        var strm = bz_stream()
        guard BZ2_bzDecompressInit(&strm, 0, 0) == BZ_OK else { throw LabError.archive("не удалось начать распаковку") }
        defer { BZ2_bzDecompressEnd(&strm) }

        let sink = TarSink(root: root)
        let outSize = 256 * 1024
        var out = [CChar](repeating: 0, count: outSize)
        var consumed = 0
        var finished = false

        while !finished {
            guard var chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            consumed += chunk.count
            try chunk.withUnsafeMutableBytes { raw in
                strm.next_in = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
                strm.avail_in = UInt32(raw.count)
                repeat {
                    strm.avail_out = UInt32(outSize)
                    let rc: Int32 = out.withUnsafeMutableBufferPointer { p in
                        strm.next_out = p.baseAddress
                        return BZ2_bzDecompress(&strm)
                    }
                    let produced = outSize - Int(strm.avail_out)
                    if produced > 0 {
                        let data = out.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: produced) }
                        try sink.feed(data)
                    }
                    if rc == BZ_STREAM_END {
                        finished = true
                        break
                    }
                    if rc != BZ_OK { throw LabError.archive("ошибка bzip2 (\(rc))") }
                } while strm.avail_in > 0 || strm.avail_out == 0
            }
            progress(min(1, Double(consumed) / Double(total)))
        }
    }
}

// MARK: - Движок Pocket TTS (sherpa-onnx, только процессор)

final class PocketEngine {
    struct Output {
        let samples: [Float]
        let rate: Int
        let firstChunk: Double?
    }

    #if canImport(SherpaOnnxC)
    private var tts: OpaquePointer?
    private var owned: [UnsafeMutablePointer<CChar>] = []
    #endif

    init(dir: URL, threads: Int) throws {
        #if canImport(SherpaOnnxC)
        var strings: [UnsafeMutablePointer<CChar>] = []
        func cs(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            strings.append(p)
            return UnsafePointer(p)
        }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.pocket.lm_flow = cs(dir.appendingPathComponent("lm_flow.int8.onnx").path)
        config.model.pocket.lm_main = cs(dir.appendingPathComponent("lm_main.int8.onnx").path)
        config.model.pocket.encoder = cs(dir.appendingPathComponent("encoder.onnx").path)
        config.model.pocket.decoder = cs(dir.appendingPathComponent("decoder.int8.onnx").path)
        config.model.pocket.text_conditioner = cs(dir.appendingPathComponent("text_conditioner.onnx").path)
        config.model.pocket.vocab_json = cs(dir.appendingPathComponent("vocab.json").path)
        config.model.pocket.token_scores_json = cs(dir.appendingPathComponent("token_scores.json").path)
        config.model.pocket.voice_embedding_cache_capacity = 20
        config.model.num_threads = Int32(threads)
        config.model.debug = 0
        config.model.provider = cs("cpu")

        guard let created = SherpaOnnxCreateOfflineTts(&config) else {
            for p in strings { free(p) }
            throw LabError.engine("не удалось загрузить модель")
        }
        tts = created
        owned = strings
        #else
        throw LabError.libraryMissing
        #endif
    }

    deinit {
        #if canImport(SherpaOnnxC)
        if let tts { SherpaOnnxDestroyOfflineTts(tts) }
        for p in owned { free(p) }
        #endif
    }

    #if canImport(SherpaOnnxC)
    private final class Box {
        var samples: [Float] = []
        let start = CFAbsoluteTimeGetCurrent()
        var firstChunk: Double?
    }
    #endif

    func generate(text: String, reference: [Float], referenceRate: Int, steps: Int) throws -> Output {
        #if canImport(SherpaOnnxC)
        guard let tts else { throw LabError.engine("движок не создан") }
        let box = Box()
        var cfg = SherpaOnnxGenerationConfig()
        cfg.silence_scale = 0.2
        cfg.speed = 1.0
        cfg.num_steps = Int32(steps)
        let extra = strdup("{\"max_reference_audio_len\": 10.0}")!
        defer { free(extra) }
        cfg.extra = UnsafePointer(extra)

        var result: UnsafePointer<SherpaOnnxGeneratedAudio>?
        reference.withUnsafeBufferPointer { ref in
            cfg.reference_audio = ref.baseAddress
            cfg.reference_audio_len = Int32(ref.count)
            cfg.reference_sample_rate = Int32(referenceRate)
            text.withCString { textPtr in
                let arg = Unmanaged.passUnretained(box).toOpaque()
                result = SherpaOnnxOfflineTtsGenerateWithConfig(tts, textPtr, &cfg, { samples, n, _, arg in
                    guard let arg else { return 1 }
                    let b = Unmanaged<Box>.fromOpaque(arg).takeUnretainedValue()
                    if let samples, n > 0 {
                        if b.firstChunk == nil { b.firstChunk = CFAbsoluteTimeGetCurrent() - b.start }
                        b.samples.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(n)))
                    }
                    return 1
                }, arg)
            }
        }

        if let audio = result {
            let n = Int(audio.pointee.n)
            let rate = Int(audio.pointee.sample_rate)
            let samples = Array(UnsafeBufferPointer(start: audio.pointee.samples, count: n))
            SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
            return Output(samples: samples, rate: rate, firstChunk: box.firstChunk)
        }
        if !box.samples.isEmpty {
            return Output(samples: box.samples, rate: 24000, firstChunk: box.firstChunk)
        }
        throw LabError.engine("модель ничего не вернула")
        #else
        throw LabError.libraryMissing
        #endif
    }
}

/// Держит движок и гоняет его на отдельной очереди (не на главном потоке).
final class PocketRunner: @unchecked Sendable {
    struct Outcome {
        let samples: [Float]
        let rate: Int
        let loadSeconds: Double
        let firstChunk: Double?
        let totalSeconds: Double
    }

    private let queue = DispatchQueue(label: "pocket.runner", qos: .userInitiated)
    private var engine: PocketEngine?
    private var loadedThreads = 0

    func reset() {
        queue.async { self.engine = nil }
    }

    func synthesize(text: String, reference: [Float], referenceRate: Int, steps: Int, threads: Int) async throws -> Outcome {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    var load = 0.0
                    if self.engine == nil || self.loadedThreads != threads {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        self.engine = nil
                        self.engine = try PocketEngine(dir: PocketFiles.dir, threads: threads)
                        self.loadedThreads = threads
                        load = CFAbsoluteTimeGetCurrent() - t0
                    }
                    guard let engine = self.engine else { throw LabError.engine("движок не создан") }
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let out = try engine.generate(text: text, reference: reference, referenceRate: referenceRate, steps: steps)
                    let total = CFAbsoluteTimeGetCurrent() - t0
                    cont.resume(returning: Outcome(
                        samples: out.samples,
                        rate: out.rate,
                        loadSeconds: load,
                        firstChunk: out.firstChunk,
                        totalSeconds: total
                    ))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Тишина, чтобы приложение не засыпало (как во время звонка)

final class SilentKeeper {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var running = false

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
        engine.attach(node)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) {
            buf.frameLength = 44100
            node.scheduleBuffer(buf, at: nil, options: .loops)
        }
        try engine.start()
        node.play()
        running = true
    }

    func stop() {
        guard running else { return }
        node.stop()
        engine.stop()
        engine.detach(node)
        running = false
    }
}

// MARK: - Голосовая лаборатория

@MainActor
final class VoiceLab: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum ModelState: Equatable {
        case missing
        case downloading(Double)
        case extracting(Double)
        case ready
        case failed(String)
    }

    @Published var modelState: ModelState = PocketFiles.isReady ? .ready : .missing
    @Published var log: [String] = []
    @Published var busy = false
    @Published var recordingSlot: RefSlot?
    @Published var recordSeconds = 0
    @Published var refDurations: [RefSlot: Double] = [:]
    @Published var selectedRef: RefSlot = .ru
    @Published var steps = 2
    @Published var threads = 2
    @Published var testText = "Hello everyone! I am testing my voice. Let's see how it sounds, and whether my accent stays."
    @Published var metrics = ""

    private let runner = PocketRunner()
    private let keeper = SilentKeeper()
    private var recorder: AVAudioRecorder?
    private var recordTimer: Timer?
    private var player: AVAudioPlayer?
    private var backgroundTestTask: Task<Void, Never>?

    override init() {
        super.init()
        refreshRefs()
    }

    // MARK: Журнал

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func note(_ s: String) {
        log.append("\(VoiceLab.timeFormat.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    var libraryAvailable: Bool {
        #if canImport(SherpaOnnxC)
        return true
        #else
        return false
        #endif
    }

    // MARK: Модель

    func downloadModel() {
        switch modelState {
        case .missing, .failed:
            startDownload()
        default:
            break
        }
    }

    private func startDownload() {
        modelState = .downloading(0)
        note("Скачиваю модель (~100 МБ)…")
        Task {
            do {
                let downloader = ModelDownloader()
                var lastUpdate = Date.distantPast
                downloader.onProgress = { [weak self] p in
                    let now = Date()
                    guard now.timeIntervalSince(lastUpdate) > 0.15 else { return }
                    lastUpdate = now
                    Task { @MainActor in self?.modelState = .downloading(p) }
                }
                let file = try await downloader.download(PocketFiles.archive, configuration: ImageLoader.shared.session.configuration)
                note("Скачано, распаковываю…")
                modelState = .extracting(0)
                let root = PocketFiles.root
                let report: @Sendable (Double) -> Void = { [weak self] p in
                    Task { @MainActor in self?.modelState = .extracting(p) }
                }
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: PocketFiles.dir)
                    var last = Date.distantPast
                    try ArchiveTools.extractTarBz2(archive: file, to: root) { p in
                        let now = Date()
                        guard now.timeIntervalSince(last) > 0.15 else { return }
                        last = now
                        report(p)
                    }
                    try? FileManager.default.removeItem(at: file)
                }.value
                if PocketFiles.isReady {
                    modelState = .ready
                    note("Модель готова (\(PocketFiles.sizeOnDisk / 1_000_000) МБ на диске)")
                } else {
                    modelState = .failed("после распаковки не хватает файлов")
                    note("Ошибка: после распаковки не хватает файлов")
                }
            } catch {
                modelState = .failed(error.localizedDescription)
                note("Ошибка: \(error.localizedDescription)")
            }
        }
    }

    func deleteModel() {
        runner.reset()
        try? FileManager.default.removeItem(at: PocketFiles.dir)
        modelState = .missing
        note("Модель удалена")
    }

    // MARK: Запись голоса

    func refreshRefs() {
        var d: [RefSlot: Double] = [:]
        for slot in RefSlot.allCases {
            let url = PocketFiles.referenceURL(slot)
            if FileManager.default.fileExists(atPath: url.path), let f = try? AVAudioFile(forReading: url) {
                d[slot] = Double(f.length) / f.processingFormat.sampleRate
            }
        }
        refDurations = d
    }

    private func prepareSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
    }

    func startRecording(_ slot: RefSlot) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.note("Нет доступа к микрофону. Разреши в Настройки → DiscClient.")
                    return
                }
                do {
                    try self.prepareSession()
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 24000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                    let rec = try AVAudioRecorder(url: PocketFiles.referenceURL(slot), settings: settings)
                    rec.delegate = self
                    guard rec.record() else { throw LabError.engine("не удалось начать запись") }
                    self.recorder = rec
                    self.recordingSlot = slot
                    self.recordSeconds = 0
                    self.recordTimer?.invalidate()
                    self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self else { return }
                            self.recordSeconds += 1
                            if self.recordSeconds >= 20 { self.stopRecording() }
                        }
                    }
                    self.note("Запись пошла (\(slot.title)). Читай фразу.")
                } catch {
                    self.note("Ошибка записи: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopRecording() {
        recordTimer?.invalidate()
        recordTimer = nil
        recorder?.stop()
        recorder = nil
        if let slot = recordingSlot {
            note("Запись сохранена (\(slot.title), \(recordSeconds) с)")
        }
        recordingSlot = nil
        refreshRefs()
    }

    func deleteRef(_ slot: RefSlot) {
        try? FileManager.default.removeItem(at: PocketFiles.referenceURL(slot))
        refreshRefs()
    }

    func playRef(_ slot: RefSlot) {
        do {
            try prepareSession()
            let p = try AVAudioPlayer(contentsOf: PocketFiles.referenceURL(slot))
            player = p
            p.play()
        } catch {
            note("Не удалось проиграть: \(error.localizedDescription)")
        }
    }

    private func loadReference(_ slot: RefSlot) throws -> ([Float], Int) {
        let url = PocketFiles.referenceURL(slot)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LabError.referenceMissing }
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw LabError.referenceMissing
        }
        try f.read(into: buf)
        guard let ch = buf.floatChannelData?[0] else { throw LabError.referenceMissing }
        return (Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))), Int(fmt.sampleRate))
    }

    // MARK: Озвучка

    private func wavData(_ samples: [Float], rate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        header.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        header.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        return header + pcm
    }

    private func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "норма"
        case .fair: return "тепло"
        case .serious: return "горячо"
        case .critical: return "перегрев"
        @unknown default: return "?"
        }
    }

    func speak(_ text: String, play: Bool = true) async -> PocketRunner.Outcome? {
        do {
            let (ref, rate) = try loadReference(selectedRef)
            let out = try await runner.synthesize(
                text: text, reference: ref, referenceRate: rate, steps: steps, threads: threads
            )
            if play {
                try prepareSession()
                let p = try AVAudioPlayer(data: wavData(out.samples, rate: out.rate))
                player = p
                p.play()
            }
            return out
        } catch {
            note("Ошибка: \(error.localizedDescription)")
            return nil
        }
    }

    func testSpeak() {
        guard !busy else { return }
        busy = true
        note("Озвучиваю: \(testText)")
        Task {
            defer { busy = false }
            guard let out = await speak(testText) else { return }
            let seconds = Double(out.samples.count) / Double(out.rate)
            let rtf = seconds > 0 ? out.totalSeconds / seconds : 0
            var lines = [String]()
            if out.loadSeconds > 0 { lines.append(String(format: "Загрузка модели: %.1f с", out.loadSeconds)) }
            if let f = out.firstChunk { lines.append(String(format: "Первый звук через: %.2f с", f)) }
            lines.append(String(format: "Речи получилось: %.1f с, считалось %.1f с", seconds, out.totalSeconds))
            lines.append(String(format: "Скорость (RTF): %.2f (меньше 1 = быстрее, чем говорится)", rtf))
            lines.append("Нагрев: \(thermalName())")
            metrics = lines.joined(separator: "\n")
            note(String(format: "Готово: RTF %.2f, речь %.1f с", rtf, seconds))
        }
    }

    // MARK: Проверка работы в фоне

    func startBackgroundTest() {
        guard !busy else { return }
        busy = true
        note("Тест в фоне: заблокируй экран примерно на 2 минуты, потом разблокируй и посмотри журнал.")
        backgroundTestTask = Task {
            defer {
                keeper.stop()
                busy = false
            }
            do {
                try keeper.start()
            } catch {
                note("Не удалось запустить звуковую сессию: \(error.localizedDescription)")
                return
            }
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                let state: String
                switch UIApplication.shared.applicationState {
                case .active: state = "на экране"
                case .inactive: state = "неактивно"
                case .background: state = "в ФОНЕ"
                @unknown default: state = "?"
                }
                let start = Date()
                if let out = await speak("Background test number \(i). This is my voice speaking.", play: false) {
                    let seconds = Double(out.samples.count) / Double(out.rate)
                    let took = Date().timeIntervalSince(start)
                    note(String(format: "#%d  %@  считалось %.1f с на %.1f с речи  нагрев: %@", i, state, took, seconds, thermalName()))
                } else {
                    note("#\(i)  \(state)  ОШИБКА")
                }
            }
            note("Тест закончен.")
        }
    }

    func cancelBackgroundTest() {
        backgroundTestTask?.cancel()
    }
}

// MARK: - Экран

struct VoiceLabView: View {
    @EnvironmentObject var store: Store
    @StateObject private var lab = VoiceLab()
    @Environment(\.dismiss) private var dismiss

    private let ruPhrase = "Сегодня я решил проверить, как звучит мой голос на другом языке. Если всё получится, друзья в голосовом канале услышат меня по-английски, а мои паузы и мой акцент останутся со мной."
    private let enPhrase = "Today I am testing how my voice sounds in another language. If everything works, my friends in the voice channel will hear me in English, with my own accent and my own pauses."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !lab.libraryAvailable {
                        card {
                            Text("Библиотека sherpa-onnx не подключена к этой сборке. Проверь шаг «Fetch sherpa-onnx» в сборке.")
                                .foregroundStyle(Color.red)
                        }
                    }
                    if store.voice.isConnected {
                        card {
                            Text("Ты сейчас в голосовом канале. Выйди из него, чтобы проверять озвучку: запись и проигрывание используют тот же звук.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    modelCard
                    referenceCard
                    testCard
                    backgroundCard
                    logCard
                }
                .padding(16)
            }
            .background(Theme.panel)
            .navigationTitle("Голосовая лаборатория")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationBackground(Theme.panel)
    }

    // MARK: Карточки

    private var modelCard: some View {
        card {
            title("1. Модель голоса")
            switch lab.modelState {
            case .missing:
                note("Один раз скачивается около 100 МБ, на телефоне занимает около 200 МБ. Дальше всё работает без интернета.")
                actionButton("Скачать модель", enabled: lab.libraryAvailable) { lab.downloadModel() }
            case .downloading(let p):
                progress("Скачиваю…", p)
            case .extracting(let p):
                progress("Распаковываю…", p)
            case .ready:
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text("Модель готова (\(PocketFiles.sizeOnDisk / 1_000_000) МБ)")
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button("Удалить") { lab.deleteModel() }
                        .font(.system(size: 13))
                        .foregroundStyle(Color.red)
                }
            case .failed(let msg):
                note("Ошибка: \(msg)")
                actionButton("Повторить", enabled: true) { lab.downloadModel() }
            }
        }
    }

    private var referenceCard: some View {
        card {
            title("2. Образец твоего голоса")
            note("Найди тихое место, держи телефон как обычно и прочитай фразу вслух своим обычным голосом, не спеша. Одной записи достаточно, но если запишешь обе, сравним, какая лучше.")

            phraseBlock("Прочитай по-русски:", ruPhrase)
            refControls(.ru)

            phraseBlock("Прочитай по-английски (со своим акцентом, как получится):", enPhrase)
            refControls(.en)
        }
    }

    private func phraseBlock(_ header: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func refControls(_ slot: RefSlot) -> some View {
        HStack(spacing: 10) {
            if lab.recordingSlot == slot {
                Button {
                    lab.stopRecording()
                } label: {
                    Label("Стоп · \(lab.recordSeconds) с", systemImage: "stop.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }
            } else {
                Button {
                    lab.startRecording(slot)
                } label: {
                    Label(lab.refDurations[slot] == nil ? "Записать" : "Перезаписать", systemImage: "mic.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.blurple, in: Capsule())
                        .foregroundStyle(.white)
                }
                .disabled(lab.recordingSlot != nil || store.voice.isConnected)
            }
            if let d = lab.refDurations[slot], lab.recordingSlot != slot {
                Button {
                    lab.playRef(slot)
                } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 26))
                        .foregroundStyle(Theme.link)
                }
                Text(String(format: "%.0f с", d))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button {
                    lab.deleteRef(slot)
                } label: {
                    Image(systemName: "trash").foregroundStyle(Color.red)
                }
            } else {
                Spacer()
            }
        }
    }

    private var testCard: some View {
        card {
            title("3. Проверка озвучки")
            HStack {
                Text("Образец")
                    .foregroundStyle(Theme.text)
                Spacer()
                Picker("", selection: $lab.selectedRef) {
                    ForEach(RefSlot.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            TextField("Фраза", text: $lab.testText, axis: .vertical)
                .lineLimit(2...5)
                .padding(10)
                .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Theme.text)
            HStack {
                Text("Качество/скорость: \(lab.steps)")
                    .foregroundStyle(Theme.text)
                Spacer()
                Stepper("", value: $lab.steps, in: 1...6).labelsHidden()
            }
            HStack {
                Text("Потоков процессора: \(lab.threads)")
                    .foregroundStyle(Theme.text)
                Spacer()
                Stepper("", value: $lab.threads, in: 1...6).labelsHidden()
            }
            actionButton(
                lab.busy ? "Считаю…" : "Озвучить",
                enabled: lab.modelState == .ready && lab.refDurations[lab.selectedRef] != nil && !lab.busy && !store.voice.isConnected
            ) { lab.testSpeak() }
            if !lab.metrics.isEmpty {
                Text(lab.metrics)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.chat, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var backgroundCard: some View {
        card {
            title("4. Работает ли при заблокированном экране")
            note("Запусти тест и сразу заблокируй телефон примерно на 2 минуты. Раз в 10 секунд приложение будет озвучивать короткую фразу. После разблокировки в журнале будет видно, шли ли расчёты в фоне и насколько быстро.")
            actionButton(
                lab.busy ? "Идёт…" : "Запустить тест",
                enabled: lab.modelState == .ready && lab.refDurations[lab.selectedRef] != nil && !lab.busy && !store.voice.isConnected
            ) { lab.startBackgroundTest() }
        }
    }

    private var logCard: some View {
        card {
            title("Журнал")
            if lab.log.isEmpty {
                note("Пока пусто")
            } else {
                ForEach(Array(lab.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Мелочи

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chat.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private func title(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Theme.text)
    }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progress(_ s: String, _ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(s) \(Int(p * 100))%")
                .foregroundStyle(Theme.text)
            ProgressView(value: p)
                .tint(Theme.blurple)
        }
    }

    private func actionButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(enabled ? Theme.blurple : Theme.blurple.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
        .disabled(!enabled)
    }
}

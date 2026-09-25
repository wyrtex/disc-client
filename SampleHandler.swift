import ReplayKit
import VideoToolbox
import CoreImage
import CoreMedia

/// Расширение трансляции экрана. Живёт под жёстким лимитом памяти (~50 МБ), поэтому всё сделано
/// «на диете»: блюр считается на уменьшенной копии кадра, буферы переиспользуются через пулы,
/// лишние кадры отбрасываются. Логика простая: обычный кадр идёт как есть, при блюре — размытый,
/// переключение живое (со следующего кадра).
class SampleHandler: RPBroadcastSampleHandler {
    private var encoder: VTCompressionSession?
    private var socket: LocalSocketClient?
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,           // не копим промежуточные буферы
        .name: "blur"
    ])
    private var blur = false
    private var blurOn: NSObjectProtocol?
    private var blurOff: NSObjectProtocol?
    private var blurToggle: NSObjectProtocol?
    private var firstFrameSent = false

    private var width = 0
    private var height = 0
    private var startTime: CMTime?
    private var forceKeyFrame = false
    private var sps: Data?
    private var pps: Data?

    // Пул уменьшенных буферов для блюра — создаётся один раз и переиспользуется.
    private var blurPool: CVPixelBufferPool?
    private var blurW = 0
    private var blurH = 0

    // Ограничение частоты: не обрабатываем больше, чем нужно, чтобы не копить память.
    private var lastEncodedPTS = CMTime.zero
    private var minFrameInterval: Double = 1.0 / 30.0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        BroadcastShared.clearExtLog()
        // Проверяем сразу, доступна ли общая папка — если нет, значит App Group не подписался.
        if BroadcastShared.logURL() == nil {
            BroadcastShared.extLog("СТАРТ, но общая папка App Group НЕдоступна — расширение подписано без группы")
        } else {
            BroadcastShared.extLog("broadcastStarted: расширение запущено, App Group доступна")
        }
        blur = BroadcastShared.blur
        minFrameInterval = 1.0 / Double(max(15, BroadcastShared.quality.fps))
        socket = LocalSocketClient()
        socket?.connect()
        BroadcastShared.extLog("сокет к приложению: попытка подключения")
        blurOn = BroadcastShared.observe(BroadcastShared.notifyBlurOn) { [weak self] in self?.setBlur(true) }
        blurOff = BroadcastShared.observe(BroadcastShared.notifyBlurOff) { [weak self] in self?.setBlur(false) }
        blurToggle = BroadcastShared.observe(BroadcastShared.notifyBlurToggle) { [weak self] in
            guard let self else { return }
            self.setBlur(!self.blur)
        }
        BroadcastShared.post(BroadcastShared.notifyStarted)
        BroadcastShared.extLog("послал сигнал 'начал' приложению")
    }

    override func broadcastFinished() {
        BroadcastShared.extLog("broadcastFinished: система остановила расширение (это может быть из-за памяти)")
        BroadcastShared.post(BroadcastShared.notifyStopped)
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        socket?.close()
        socket = nil
    }

    private func setBlur(_ on: Bool) {
        blur = on
        BroadcastShared.defaults?.set(on, forKey: BroadcastShared.keyBlur)
        forceKeyFrame = true
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = pts
            BroadcastShared.extLog("первый видеокадр получен: \(CVPixelBufferGetWidth(source))x\(CVPixelBufferGetHeight(source))")
        }

        // Пропускаем лишние кадры, чтобы не переполнять память очередью.
        if lastEncodedPTS != .zero {
            let dt = CMTimeGetSeconds(CMTimeSubtract(pts, lastEncodedPTS))
            if dt < minFrameInterval * 0.9 { return }
        }
        lastEncodedPTS = pts

        // autoreleasepool: временные объекты CoreImage освобождаются сразу после кадра.
        autoreleasepool {
            var pixelBuffer = source
            if blur, let blurred = makeBlurred(source) {
                pixelBuffer = blurred
            }
            ensureEncoder(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            guard let encoder else { return }

            var props: [String: Any]? = nil
            if forceKeyFrame {
                props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
                forceKeyFrame = false
            }
            VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                frameProperties: props as CFDictionary?, infoFlagsOut: nil,
                outputHandler: { [weak self] status, _, sb in
                    guard status == noErr, let sb, let self else { return }
                    self.emit(sb)
                }
            )
        }
    }

    // MARK: Блюр (на уменьшенной копии — визуально то же, а памяти в разы меньше)

    private func makeBlurred(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input)
        let h = CVPixelBufferGetHeight(input)
        guard w > 0, h > 0 else { return nil }
        // Блюр всё равно съедает детали, поэтому сначала уменьшаем кадр до ~360p — так буфер
        // в разы меньше. При растягивании обратно размытие выглядит так же сильно.
        let targetH = 360
        let scale = min(1.0, Double(targetH) / Double(h))
        let sw = max(16, Int(Double(w) * scale))
        let sh = max(16, Int(Double(h) * scale))

        if blurPool == nil || blurW != sw || blurH != sh {
            blurW = sw; blurH = sh
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(input),
                kCVPixelBufferWidthKey as String: sw,
                kCVPixelBufferHeightKey as String: sh,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
            blurPool = pool
        }
        guard let pool = blurPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }

        let ci = CIImage(cvPixelBuffer: input)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
            .cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh))
        ciContext.render(ci, to: out)
        return out
    }

    // MARK: Кодирование H264

    private func ensureEncoder(width: Int, height: Int) {
        if encoder != nil, width == self.width, height == self.height { return }
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        self.width = width
        self.height = height
        let q = BroadcastShared.quality
        var session: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                   codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: q.fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: q.bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (q.fps * 2) as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        forceKeyFrame = true
    }

    private func emit(_ sb: CMSampleBuffer) {
        let isKey = !((CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            extractParams(fmt)
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &len, totalLengthOut: &total, dataPointerOut: &ptr) == noErr, let ptr else { return }

        var annexb = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        if isKey, let sps, let pps {
            annexb.append(contentsOf: startCode); annexb.append(sps)
            annexb.append(contentsOf: startCode); annexb.append(pps)
        }
        var offset = 0
        while offset + 4 <= total {
            let nalLen = Int(UInt32(bigEndian: UnsafeRawPointer(ptr + offset).load(as: UInt32.self)))
            offset += 4
            guard offset + nalLen <= total, nalLen > 0 else { break }
            annexb.append(contentsOf: startCode)
            annexb.append(Data(bytes: ptr + offset, count: nalLen))
            offset += nalLen
        }
        socket?.send(BroadcastWire.frame(type: BroadcastWire.typeVideo, annexb))
        if !firstFrameSent {
            firstFrameSent = true
            BroadcastShared.extLog("первый кадр закодирован и отправлен в приложение (\(annexb.count) байт)")
        }
    }

    private func extractParams(_ fmt: CMFormatDescription) {
        var sPtr: UnsafePointer<UInt8>?; var sLen = 0
        var pPtr: UnsafePointer<UInt8>?; var pLen = 0
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: &sPtr, parameterSetSizeOut: &sLen, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1, parameterSetPointerOut: &pPtr, parameterSetSizeOut: &pLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        if let sPtr { sps = Data(bytes: sPtr, count: sLen) }
        if let pPtr { pps = Data(bytes: pPtr, count: pLen) }
    }
}

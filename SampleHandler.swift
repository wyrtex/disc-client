import ReplayKit
import VideoToolbox
import CoreMedia

/// Расширение трансляции экрана. Жёсткий лимит памяти ~50 МБ, поэтому главное правило:
/// НИКОГДА не кодируем кадр в полном разрешении экрана. Каждый кадр аппаратно уменьшается
/// до 720p (VTPixelTransferSession) и только потом кодируется H264. Без блюра и записи —
/// ради стабильности (их можно вернуть позже). Кадры уходят в приложение по localhost-сокету.
class SampleHandler: RPBroadcastSampleHandler {
    private var encoder: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var scalePool: CVPixelBufferPool?
    private var socket: LocalSocketClient?

    private var stopCmd: NSObjectProtocol?
    private var forceKeyframeObs: NSObjectProtocol?

    private var dstW = 0
    private var dstH = 0
    private var startTime: CMTime?
    private var forceKeyFrame = false
    private var sps: Data?
    private var pps: Data?
    private var firstFrameSent = false

    // Ограничение частоты кадров — не копим память очередью.
    private var lastEncodedPTS = CMTime.zero
    private var minFrameInterval: Double = 1.0 / 30.0

    // Максимальная сторона кадра. Больше — риск вылета по памяти в расширении.
    private static let maxSide = 1280

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        BroadcastShared.post(BroadcastShared.beaconStarted)
        minFrameInterval = 1.0 / Double(max(15, BroadcastShared.quality.fps))

        socket = LocalSocketClient()
        socket?.onConnected = { BroadcastShared.post(BroadcastShared.beaconSocketOK) }
        socket?.connect()

        forceKeyframeObs = BroadcastShared.observe(BroadcastShared.notifyForceKeyframe) { [weak self] in
            self?.forceKeyFrame = true
        }
        stopCmd = BroadcastShared.observe(BroadcastShared.notifyStopCommand) { [weak self] in
            guard let self else { return }
            let err = NSError(domain: "DiscClient", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "Трансляция остановлена"])
            self.finishBroadcastWithError(err)
        }
        BroadcastShared.post(BroadcastShared.notifyStarted)
    }

    override func broadcastFinished() {
        BroadcastShared.post(BroadcastShared.notifyStopped)
        stopCmd = nil
        forceKeyframeObs = nil
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
        transfer = nil
        scalePool = nil
        socket?.close()
        socket = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = pts
            BroadcastShared.post(BroadcastShared.beaconFirstVideo)
        }

        // Пропуск лишних кадров.
        if lastEncodedPTS != .zero {
            let dt = CMTimeGetSeconds(CMTimeSubtract(pts, lastEncodedPTS))
            if dt < minFrameInterval * 0.9 { return }
        }
        lastEncodedPTS = pts

        autoreleasepool {
            let srcW = CVPixelBufferGetWidth(source)
            let srcH = CVPixelBufferGetHeight(source)
            let (tw, th) = Self.fitSize(srcW, srcH)
            guard tw > 0, th > 0 else { return }

            ensureScaler(width: tw, height: th)
            ensureEncoder(width: tw, height: th)
            guard let transfer, let pool = scalePool, let encoder else { return }

            // Берём буфер 720p из пула и аппаратно уменьшаем в него исходный кадр.
            var scaled: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled) == kCVReturnSuccess,
                  let dst = scaled else { return }
            guard VTPixelTransferSessionTransferImage(transfer, from: source, to: dst) == noErr else { return }

            var props: [String: Any]? = nil
            if forceKeyFrame {
                props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
                forceKeyFrame = false
            }
            VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: dst, presentationTimeStamp: pts, duration: .invalid,
                frameProperties: props as CFDictionary?, infoFlagsOut: nil,
                outputHandler: { [weak self] status, _, sb in
                    guard status == noErr, let sb, let self else { return }
                    self.emit(sb)
                }
            )
        }
    }

    /// Вписываем размер в maxSide, сохраняя пропорции; стороны чётные (требование H264).
    private static func fitSize(_ w: Int, _ h: Int) -> (Int, Int) {
        guard w > 0, h > 0 else { return (0, 0) }
        let longest = max(w, h)
        let scale = longest > maxSide ? Double(maxSide) / Double(longest) : 1.0
        var tw = Int((Double(w) * scale).rounded())
        var th = Int((Double(h) * scale).rounded())
        tw -= tw % 2
        th -= th % 2
        return (max(2, tw), max(2, th))
    }

    private func ensureScaler(width: Int, height: Int) {
        if transfer != nil, scalePool != nil, width == dstW, height == dstH { return }
        dstW = width; dstH = height

        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
        var ts: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &ts)
        if let ts {
            // dst сохраняет пропорции источника, поэтому Normal = ровное масштабирование без искажений.
            VTSessionSetProperty(ts, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            transfer = ts
        }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 2]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        scalePool = pool
    }

    private func ensureEncoder(width: Int, height: Int) {
        if encoder != nil, width == dstW, height == dstH, encoderReady { return }
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        let q = BroadcastShared.quality
        let bitrate = min(q.bitrate, 3_000_000)   // держим поток разумным
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int32(q.fps) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        encoderReady = true
        forceKeyFrame = true
    }
    private var encoderReady = false

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
            BroadcastShared.post(BroadcastShared.beaconFirstSend)
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

import ReplayKit
import VideoToolbox
import CoreImage
import CoreMedia

/// Расширение трансляции экрана. Захватывает кадры всего экрана, при включённом блюре размывает
/// их на видеочипе, кодирует в H264 и отправляет в основное приложение через локальный сокет.
/// Блюр можно включать и выключать в любой момент — по межпроцессному сигналу.
class SampleHandler: RPBroadcastSampleHandler {
    private var encoder: VTCompressionSession?
    private var socket: LocalSocketClient?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var blur = BroadcastShared.blur
    private var blurOn: NSObjectProtocol?
    private var blurOff: NSObjectProtocol?
    private var blurToggle: NSObjectProtocol?
    private var width = 0
    private var height = 0
    private var startTime: CMTime?
    private var forceKeyFrame = false
    private var sps: Data?
    private var pps: Data?
    private var recorder: StreamRecorder?
    private var recordAudio = false
    private var recordStarted = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        blur = BroadcastShared.blur
        socket = LocalSocketClient()
        socket?.connect()
        blurOn = BroadcastShared.observe(BroadcastShared.notifyBlurOn) { [weak self] in self?.setBlur(true) }
        blurOff = BroadcastShared.observe(BroadcastShared.notifyBlurOff) { [weak self] in self?.setBlur(false) }
        blurToggle = BroadcastShared.observe(BroadcastShared.notifyBlurToggle) { [weak self] in
            guard let self else { return }
            self.setBlur(!self.blur)
        }
        if BroadcastShared.record {
            recorder = StreamRecorder()
            recordAudio = BroadcastShared.streamAudio
        }
        BroadcastShared.post(BroadcastShared.notifyStarted)
    }

    override func broadcastFinished() {
        if let rec = recorder {
            rec.finish { url in
                if let url {
                    BroadcastShared.defaults?.set(url.path, forKey: BroadcastShared.keyLastRecording)
                    BroadcastShared.post(BroadcastShared.notifyRecordingReady)
                }
            }
        }
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
        if sampleBufferType == .audioApp {
            if recordAudio { recorder?.appendAudio(sampleBuffer) }
            return
        }
        guard sampleBufferType == .video else { return }
        guard var pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil { startTime = pts }

        if blur, let blurred = makeBlurred(pixelBuffer) {
            pixelBuffer = blurred
        }

        if let rec = recorder {
            if !recordStarted {
                rec.start(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer),
                          includeAudio: recordAudio)
                recordStarted = true
            }
            appendToRecorder(pixelBuffer, pts: pts, original: sampleBuffer)
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
                self.emit(sb, pts: pts)
            }
        )
    }

    /// Кладём кадр в запись. Если блюр применён, оборачиваем размытый буфер в новый sample buffer
    /// с тем же временем; иначе пишем оригинал напрямую.
    private func appendToRecorder(_ pixelBuffer: CVPixelBuffer, pts: CMTime, original: CMSampleBuffer) {
        guard let rec = recorder else { return }
        if CMSampleBufferGetImageBuffer(original) === pixelBuffer {
            rec.appendVideo(original)
            return
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb { rec.appendVideo(sb) }
    }

    // MARK: Блюр (на видеочипе, поэтому переключение почти мгновенное)

    private var blurPool: CVPixelBufferPool?

    private func makeBlurred(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input)
        let h = CVPixelBufferGetHeight(input)
        var ci = CIImage(cvPixelBuffer: input)
        // Сильное размытие: даже мелкий текст становится нечитаемым.
        let clamped = ci.clampedToExtent()
        ci = clamped.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28])
            .cropped(to: CIImage(cvPixelBuffer: input).extent)

        if blurPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(input),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &blurPool)
        }
        guard let pool = blurPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
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

    private func emit(_ sb: CMSampleBuffer, pts: CMTime) {
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

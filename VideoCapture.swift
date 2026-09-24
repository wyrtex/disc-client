import Foundation
import AVFoundation
import VideoToolbox
import UIKit

/// Захват с камеры, кодирование в H264 (VideoToolbox) и раздача готовых NAL-юнитов наружу.
/// Сам по себе не знает про Discord — просто "камера -> H264 кадры", подключается в VoiceMedia.
final class CameraSource: NSObject {
    struct EncodedFrame {
        let nalUnits: [Data]   // NAL-юниты кадра, каждый БЕЗ старт-кода (00 00 00 01)
        let isKeyFrame: Bool
        let timestamp: UInt32  // 90 кГц клок, как принято для видео в RTP
    }

    /// Готовый кадр для отправки. Вызывается на фоновой очереди.
    var onFrame: ((EncodedFrame) -> Void)?
    /// Параметры SPS/PPS изменились (например, при первом кадре) — их нужно слать перед каждым ключевым кадром.
    var onParameterSets: ((_ sps: Data, _ pps: Data) -> Void)?
    var onError: ((String) -> Void)?
    /// Локальный превью-слой для своей плитки (не имеет отношения к отправке).
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.capture")
    private var output: AVCaptureVideoDataOutput?
    private var compressionSession: VTCompressionSession?
    private var currentInput: AVCaptureDeviceInput?
    private(set) var position: AVCaptureDevice.Position = .front
    private var startTime: CMTime?
    private var forceKeyFrame = false
    private var sps: Data?
    private var pps: Data?

    private static let targetWidth = 640
    private static let targetHeight = 480
    private static let fps: Int32 = 24
    private static let bitrate = 900_000

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { completion(ok) } }
        default:
            completion(false)
        }
    }

    func start(position: AVCaptureDevice.Position = .front) {
        queue.async { [weak self] in
            self?.startInternal(position: position)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            if let cs = self.compressionSession {
                VTCompressionSessionInvalidate(cs)
            }
            self.compressionSession = nil
            self.startTime = nil
        }
    }

    /// Переключить фронтальную/тыловую камеру на лету, без остановки звонка.
    func flip() {
        queue.async { [weak self] in
            guard let self, let input = self.currentInput else { return }
            let newPosition: AVCaptureDevice.Position = self.position == .front ? .back : .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            self.session.removeInput(input)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.currentInput = newInput
                self.position = newPosition
            } else {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
            self.forceKeyFrame = true
        }
    }

    private func startInternal(position: AVCaptureDevice.Position) {
        self.position = position
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            onError?("Не удалось открыть камеру")
            return
        }
        session.addInput(input)
        currentInput = input

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else {
            session.commitConfiguration()
            onError?("Не удалось подключить вывод камеры")
            return
        }
        session.addOutput(out)
        output = out
        if let conn = out.connection(with: .video) {
            conn.videoRotationAngle = position == .front ? 270 : 90
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = position == .front }
        }
        session.commitConfiguration()

        setupEncoder()
        startTime = nil
        forceKeyFrame = true
        session.startRunning()
    }

    private func setupEncoder() {
        if let cs = compressionSession { VTCompressionSessionInvalidate(cs) }
        var cs: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(CameraSource.targetWidth),
            height: Int32(CameraSource.targetHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &cs
        )
        guard status == noErr, let session = cs else {
            onError?("Не удалось создать кодировщик H264")
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: CameraSource.fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: CameraSource.bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (CameraSource.fps * 2) as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool, pts: CMTime) {
        guard let start = startTime else { return }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, start))
        let ts90k = UInt32(truncatingIfNeeded: Int64((seconds * 90000).rounded()))

        if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            extractParameterSets(formatDesc)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }

        var nalUnits: [Data] = []
        if isKeyFrame, let sps, let pps {
            nalUnits.append(sps)
            nalUnits.append(pps)
        }

        var offset = 0
        while offset + 4 <= totalLength {
            let lenBytes = dataPointer + offset
            let nalLength = Int(UInt32(bigEndian: UnsafeRawPointer(lenBytes).load(as: UInt32.self)))
            offset += 4
            guard offset + nalLength <= totalLength, nalLength > 0 else { break }
            nalUnits.append(Data(bytes: dataPointer + offset, count: nalLength))
            offset += nalLength
        }
        guard !nalUnits.isEmpty else { return }
        onFrame?(EncodedFrame(nalUnits: nalUnits, isKeyFrame: isKeyFrame, timestamp: ts90k))
    }

    private func extractParameterSets(_ formatDesc: CMFormatDescription) {
        var spsPointer: UnsafePointer<UInt8>?
        var spsLength = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsLength = 0
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsLength, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsLength, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard let spsPointer, let ppsPointer else { return }
        let spsData = Data(bytes: spsPointer, count: spsLength)
        let ppsData = Data(bytes: ppsPointer, count: ppsLength)
        sps = spsData
        pps = ppsData
        onParameterSets?(spsData, ppsData)
    }
}

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let compressionSession, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil { startTime = pts }

        var flags: VTEncodeInfoFlags = []
        var properties: [String: Any]? = nil
        if forceKeyFrame {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
            forceKeyFrame = false
        }

        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties as CFDictionary?,
            infoFlagsOut: &flags,
            outputHandler: { [weak self] status, infoFlags, sampleBuffer in
                guard status == noErr, let sampleBuffer, let self else { return }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
                let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
                self.handleEncoded(sampleBuffer, isKeyFrame: !notSync, pts: pts)
            }
        )
    }
}

// MARK: - SwiftUI-обёртка превью-слоя

import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let source: CameraSource

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.layer.addSublayer(source.previewLayer)
        return v
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        uiView.previewLayer = source.previewLayer
    }

    final class PreviewContainer: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}

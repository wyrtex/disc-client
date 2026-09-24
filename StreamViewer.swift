import Foundation
import Network
import CryptoKit
import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

// MARK: - H264 Annex-B: разбиение кадра на NAL-юниты

enum H264AnnexB {
    /// Делит кадр вида 00 00 00 01 NAL 00 00 01 NAL ... на NAL-юниты без стартовых кодов.
    static func split(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(codeStart: Int, nalStart: Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                let codeStart = (i > 0 && b[i - 1] == 0) ? i - 1 : i
                starts.append((codeStart, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var out: [Data] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].codeStart : b.count
            if end > s.nalStart { out.append(Data(b[s.nalStart..<end])) }
        }
        return out
    }

    static func join(_ nals: [Data]) -> Data {
        var d = Data()
        for n in nals {
            d.append(contentsOf: [0, 0, 0, 1])
            d.append(n)
        }
        return d
    }
}

// MARK: - Экран, куда выводятся кадры демонстрации

final class StreamDisplay {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func enqueue(_ sb: CMSampleBuffer) {
        DispatchQueue.main.async {
            let r = self.layer.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sb)
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
}

struct StreamPlayerView: UIViewRepresentable {
    let display: StreamDisplay

    func makeUIView(context: Context) -> Container {
        let v = Container()
        v.backgroundColor = .black
        v.layer.addSublayer(display.layer)
        v.videoLayer = display.layer
        return v
    }

    func updateUIView(_ uiView: Container, context: Context) {}

    final class Container: UIView {
        var videoLayer: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - Приём видео демонстрации по отдельному соединению стрима

/// UDP -> транспортная расшифровка -> RTP -> сборка H264-кадра -> DAVE -> вывод на экран.
final class StreamVideoReceiver {
    private let connection: NWConnection
    private let key: SymmetricKey
    private let dave: DaveSession?
    private let display: StreamDisplay
    private let queue = DispatchQueue(label: "stream.video")

    var log: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?

    static let h264PayloadType = 101

    private var videoSsrcs: [UInt32: String] = [:]
    private var stopped = false

    // Сборка текущего кадра
    private var curTs: UInt32?
    private var nals: [Data] = []
    private var fu: Data?
    private var lastSeq: UInt16?
    private var frameBroken = false

    // Декодирование
    private var sps: Data?
    private var pps: Data?
    private var formatDesc: CMVideoFormatDescription?
    private var waitingKeyframe = true
    private var shownFirst = false

    private struct Stats: Equatable {
        var packets = 0
        var unknownSsrc = 0
        var otherPayload = 0
        var lost = 0
        var frames = 0
        var shown = 0
        var daveFail = 0
        var dropped = 0
    }
    private var stats = Stats()
    private var lastStats = Stats()
    private var seenPayloadTypes = Set<Int>()
    private var timer: DispatchSourceTimer?
    private var keepalive: DispatchSourceTimer?
    private var keepaliveCounter: UInt64 = 0

    init(connection: NWConnection, secretKey: Data, dave: DaveSession?, display: StreamDisplay) {
        self.connection = connection
        self.key = SymmetricKey(data: secretKey)
        self.dave = dave
        self.display = display
    }

    func setVideo(ssrc: UInt32, user: String) {
        queue.async { self.videoSsrcs[ssrc] = user }
    }

    func start() {
        receiveLoop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.report() }
        t.resume()
        timer = t

        let k = DispatchSource.makeTimerSource(queue: queue)
        k.schedule(deadline: .now() + 1, repeating: 4)
        k.setEventHandler { [weak self] in
            guard let self else { return }
            var c = self.keepaliveCounter.bigEndian
            self.keepaliveCounter &+= 1
            self.connection.send(content: Data(bytes: &c, count: 8), completion: .contentProcessed { _ in })
        }
        k.resume()
        keepalive = k
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.keepalive?.cancel()
            self.keepalive = nil
        }
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.queue.async { self.handlePacket(data) }
            }
            if error == nil { self.receiveLoop() }
        }
    }

    private func report() {
        guard stats != lastStats else { return }
        lastStats = stats
        log?("Демонстрация: пакетов \(stats.packets), кадров \(stats.frames), показано \(stats.shown). Потери \(stats.lost), выброшено кадров \(stats.dropped), DAVE ошибок \(stats.daveFail), чужих ssrc \(stats.unknownSsrc), другой кодек \(stats.otherPayload)")
    }

    // MARK: Пакет

    private func handlePacket(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return }
        let pt = Int(bytes[1] & 0x7F)
        // RTCP (200...206 с учётом бита маркера) пропускаем.
        if bytes[1] >= 200 && bytes[1] <= 206 { return }
        let marker = (bytes[1] & 0x80) != 0
        let seq = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        var ssrc: UInt32 = 0
        for i in 8..<12 { ssrc = (ssrc << 8) | UInt32(bytes[i]) }
        var ts: UInt32 = 0
        for i in 4..<8 { ts = (ts << 8) | UInt32(bytes[i]) }

        guard let user = videoSsrcs[ssrc] else {
            stats.unknownSsrc += 1
            return
        }
        if !seenPayloadTypes.contains(pt) {
            seenPayloadTypes.insert(pt)
            log?("[видео/демо] Первый пакет демонстрации: ssrc \(ssrc), payload type \(pt), \(bytes.count) байт")
        }
        guard pt == StreamVideoReceiver.h264PayloadType else {
            stats.otherPayload += 1
            return
        }
        guard let payload = openTransport(bytes) else { return }
        stats.packets += 1
        depacketize([UInt8](payload), ts: ts, seq: seq, marker: marker, user: user)
    }

    private func openTransport(_ bytes: [UInt8]) -> Data? {
        guard bytes.count >= 12 + 16 + 4 else { return nil }
        let b0 = bytes[0]
        let cc = Int(b0 & 0x0F)
        let hasExtension = (b0 & 0x10) != 0
        var headerLen = 12 + cc * 4
        var extWords = 0
        if hasExtension {
            guard bytes.count >= headerLen + 4 else { return nil }
            extWords = Int(bytes[headerLen + 2]) << 8 | Int(bytes[headerLen + 3])
            headerLen += 4
        }
        guard bytes.count >= headerLen + 16 + 4 else { return nil }
        let tagStart = bytes.count - 4 - 16
        let cipher = Data(bytes[headerLen..<tagStart])
        let tag = Data(bytes[tagStart..<(bytes.count - 4)])
        var nonceData = Data(bytes[(bytes.count - 4)...])
        nonceData.append(Data(count: 8))
        let aad = Data(bytes[0..<headerLen])
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad) else { return nil }
        let n = extWords * 4
        guard plain.count >= n else { return nil }
        return Data(plain.dropFirst(n))
    }

    // MARK: Сборка H264 из RTP (RFC 6184)

    private func depacketize(_ p: [UInt8], ts: UInt32, seq: UInt16, marker: Bool, user: String) {
        if curTs != ts {
            if curTs != nil { finishFrame(user: user) }
            curTs = ts
            nals = []
            fu = nil
            frameBroken = false
        }
        if let last = lastSeq, seq != last &+ 1 {
            frameBroken = true
            stats.lost += 1
        }
        lastSeq = seq
        guard !p.isEmpty else { return }

        let type = p[0] & 0x1F
        switch type {
        case 1...23:
            nals.append(Data(p))
        case 24:
            // STAP-A: несколько NAL подряд, у каждого 2 байта длины.
            var i = 1
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.count else { break }
                nals.append(Data(p[i..<(i + size)]))
                i += size
            }
        case 28:
            // FU-A: кусок большого NAL.
            guard p.count > 2 else { break }
            let indicator = p[0]
            let header = p[1]
            let isStart = (header & 0x80) != 0
            let isEnd = (header & 0x40) != 0
            if isStart {
                var d = Data([(indicator & 0xE0) | (header & 0x1F)])
                d.append(contentsOf: p[2...])
                fu = d
            } else if fu != nil {
                fu?.append(contentsOf: p[2...])
            } else {
                frameBroken = true
            }
            if isEnd, let f = fu {
                nals.append(f)
                fu = nil
            }
        default:
            break
        }

        if marker {
            finishFrame(user: user)
            curTs = nil
        }
    }

    private func finishFrame(user: String) {
        defer {
            nals = []
            fu = nil
        }
        guard !nals.isEmpty else { return }
        stats.frames += 1
        if frameBroken {
            waitingKeyframe = true
            stats.dropped += 1
            return
        }
        var frame = H264AnnexB.join(nals)
        // Кадр с E2EE заканчивается маркером 0xFAFA.
        let n = frame.count
        if n >= 2, frame[frame.startIndex + n - 1] == 0xFA, frame[frame.startIndex + n - 2] == 0xFA {
            guard let dave, let dec = dave.decryptVideo(userId: user, frame: frame) else {
                stats.daveFail += 1
                waitingKeyframe = true
                return
            }
            frame = dec
        }
        decode(H264AnnexB.split(frame))
    }

    // MARK: Вывод

    private func decode(_ units: [Data]) {
        var vcl: [Data] = []
        var isKey = false
        var newSps: Data?
        var newPps: Data?
        for u in units {
            guard let first = u.first else { continue }
            switch first & 0x1F {
            case 7: newSps = u
            case 8: newPps = u
            case 5:
                isKey = true
                vcl.append(u)
            case 1:
                vcl.append(u)
            default:
                break
            }
        }
        if let s = newSps, let p = newPps, s != sps || p != pps {
            sps = s
            pps = p
            formatDesc = makeFormat(sps: s, pps: p)
            if formatDesc == nil { log?("Демонстрация: не удалось разобрать параметры видео (SPS/PPS)") }
        }
        if waitingKeyframe {
            guard isKey else {
                stats.dropped += 1
                return
            }
            waitingKeyframe = false
        }
        guard let fd = formatDesc, !vcl.isEmpty, let sb = makeSample(vcl, format: fd) else { return }
        display.enqueue(sb)
        stats.shown += 1
        if !shownFirst {
            shownFirst = true
            log?("[видео/демо] Первый кадр демонстрации показан")
            onFirstFrame?()
        }
    }

    private func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var fd: CMFormatDescription?
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        let status: OSStatus = spsBytes.withUnsafeBufferPointer { s in
            ppsBytes.withUnsafeBufferPointer { p in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes: [Int] = [spsBytes.count, ppsBytes.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fd
                )
            }
        }
        return status == noErr ? fd : nil
    }

    private func makeSample(_ vcl: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data()
        for u in vcl {
            var len = UInt32(u.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(u)
        }
        let length = avcc.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied: OSStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

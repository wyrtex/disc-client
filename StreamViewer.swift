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

/// UDP -> транспортная расшифровка -> буфер переупорядочивания (+ запросы повторов NACK/RTX) ->
/// сборка H264-кадра -> DAVE -> вывод на экран. При потере кадра просим ключевой кадр (PLI).
final class StreamVideoReceiver {
    private let connection: NWConnection
    private let key: SymmetricKey
    private let dave: DaveSession?
    private let display: StreamDisplay
    private let ownSsrc: UInt32
    private let queue = DispatchQueue(label: "stream.video")

    var log: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?

    static let h264PayloadType = 101
    static let rtxPayloadType = 102

    private struct Pkt {
        let payload: [UInt8]
        let ts: UInt32
        let marker: Bool
    }

    private var videoSsrcs: [UInt32: String] = [:]
    private var rtxToPrimary: [UInt32: UInt32] = [:]
    private var stopped = false

    // Буфер переупорядочивания (по номерам пакетов)
    private var buffer: [UInt16: Pkt] = [:]
    private var bufferSsrc: UInt32 = 0
    private var expectedSeq: UInt16?
    private var missingSince: Date?
    private var nacked = Set<UInt16>()

    // Сборка текущего кадра
    private var curTs: UInt32?
    private var nals: [Data] = []
    private var fu: Data?
    private var frameBroken = false

    // Декодирование
    private var sps: Data?
    private var pps: Data?
    private var formatDesc: CMVideoFormatDescription?
    private var waitingKeyframe = true
    private var shownFirst = false
    private var lastPli = Date.distantPast

    // RTCP
    private var rtcpNonce: UInt32 = 0

    private struct Stats: Equatable {
        var packets = 0
        var rtx = 0
        var unknownSsrc = 0
        var otherPayload = 0
        var skipped = 0
        var frames = 0
        var shown = 0
        var daveFail = 0
        var dropped = 0
        var nack = 0
        var pli = 0
    }
    private var stats = Stats()
    private var lastStats = Stats()
    private var seenPayloadTypes = Set<Int>()
    private var timer: DispatchSourceTimer?
    private var tick: DispatchSourceTimer?
    private var keepalive: DispatchSourceTimer?
    private var keepaliveCounter: UInt64 = 0

    init(connection: NWConnection, secretKey: Data, dave: DaveSession?, display: StreamDisplay, ownSsrc: UInt32) {
        self.connection = connection
        self.key = SymmetricKey(data: secretKey)
        self.dave = dave
        self.display = display
        self.ownSsrc = ownSsrc
    }

    func setVideo(ssrc: UInt32, user: String, rtx: UInt32?) {
        queue.async {
            self.videoSsrcs[ssrc] = user
            if let rtx, rtx != 0 { self.rtxToPrimary[rtx] = ssrc }
            // Сразу просим ключевой кадр, чтобы не ждать следующего по расписанию.
            self.requestKeyframe(ssrc, force: true)
        }
    }

    func start() {
        receiveLoop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.report() }
        t.resume()
        timer = t

        // Проверка «застрявших» пропусков и повторные просьбы о ключевом кадре.
        let tk = DispatchSource.makeTimerSource(queue: queue)
        tk.schedule(deadline: .now() + 0.05, repeating: 0.05)
        tk.setEventHandler { [weak self] in
            guard let self else { return }
            self.drainStale()
            if self.waitingKeyframe, self.bufferSsrc != 0 { self.requestKeyframe(self.bufferSsrc, force: false) }
        }
        tk.resume()
        tick = tk

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
            self.tick?.cancel()
            self.tick = nil
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
        log?("Демонстрация: пакетов \(stats.packets) (+повторов \(stats.rtx)), кадров \(stats.frames), показано \(stats.shown). Пропущено пакетов \(stats.skipped), выброшено кадров \(stats.dropped), DAVE ошибок \(stats.daveFail), NACK \(stats.nack), запросов ключевого кадра \(stats.pli)")
    }

    // MARK: Пакет

    private func handlePacket(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return }
        if bytes[1] >= 200 && bytes[1] <= 206 { return } // RTCP от сервера
        let pt = Int(bytes[1] & 0x7F)
        let marker = (bytes[1] & 0x80) != 0
        let seq = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        var ssrc: UInt32 = 0
        for i in 8..<12 { ssrc = (ssrc << 8) | UInt32(bytes[i]) }
        var ts: UInt32 = 0
        for i in 4..<8 { ts = (ts << 8) | UInt32(bytes[i]) }

        if let primary = rtxToPrimary[ssrc] {
            // Повтор потерянного пакета: в начале 2 байта исходного номера.
            guard pt == StreamVideoReceiver.rtxPayloadType, let p = openTransport(bytes), p.count > 2 else { return }
            let original = UInt16(p[0]) << 8 | UInt16(p[1])
            stats.rtx += 1
            insert(ssrc: primary, seq: original, pkt: Pkt(payload: Array(p[2...]), ts: ts, marker: marker))
            return
        }
        guard videoSsrcs[ssrc] != nil else {
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
        guard let p = openTransport(bytes) else { return }
        stats.packets += 1
        insert(ssrc: ssrc, seq: seq, pkt: Pkt(payload: p, ts: ts, marker: marker))
    }

    /// Транспортная расшифровка (aead_aes256_gcm_rtpsize). Убирает расширения заголовка и
    /// RTP-заполнение (padding), иначе в кадр попадают лишние байты и DAVE не сходится.
    private func openTransport(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 12 + 16 + 4 else { return nil }
        let b0 = bytes[0]
        let hasPadding = (b0 & 0x20) != 0
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
        var p = [UInt8](plain)
        let n = extWords * 4
        guard p.count >= n else { return nil }
        p.removeFirst(n)
        if hasPadding, let pad = p.last {
            let padCount = Int(pad)
            guard padCount <= p.count else { return nil }
            p.removeLast(padCount)
        }
        return p
    }

    // MARK: Буфер переупорядочивания

    private func dist(_ a: UInt16, _ b: UInt16) -> Int {
        Int(Int16(bitPattern: a &- b))
    }

    private func insert(ssrc: UInt32, seq: UInt16, pkt: Pkt) {
        if ssrc != bufferSsrc {
            bufferSsrc = ssrc
            buffer = [:]
            expectedSeq = nil
            nacked = []
            resetFrame()
            waitingKeyframe = true
        }
        if expectedSeq == nil { expectedSeq = seq }
        guard let expected = expectedSeq, dist(seq, expected) >= 0 else { return } // уже пропущен
        buffer[seq] = pkt
        drain()
        requestMissing()
    }

    /// Отдаём пакеты по порядку, пока нет дыры.
    private func drain() {
        guard var expected = expectedSeq else { return }
        while let p = buffer.removeValue(forKey: expected) {
            depacketize(p)
            expected = expected &+ 1
        }
        expectedSeq = expected
        if buffer.isEmpty {
            missingSince = nil
        } else if missingSince == nil {
            missingSince = Date()
        }
    }

    /// Если дыра не закрылась за 150 мс (или буфер разросся), пропускаем её и ждём ключевой кадр.
    private func drainStale() {
        guard !buffer.isEmpty, let since = missingSince, let expected = expectedSeq else { return }
        let tooOld = Date().timeIntervalSince(since) > 0.15
        let tooBig = buffer.count > 400
        guard tooOld || tooBig else { return }
        guard let next = buffer.keys.min(by: { dist($0, expected) < dist($1, expected) }) else { return }
        stats.skipped += max(0, dist(next, expected))
        expectedSeq = next
        frameBroken = true
        missingSince = nil
        drain()
    }

    /// Просим сервер повторить пропавшие пакеты (Generic NACK), каждый номер не больше одного раза.
    private func requestMissing() {
        guard let expected = expectedSeq, !buffer.isEmpty,
              let maxSeq = buffer.keys.max(by: { dist($0, expected) < dist($1, expected) }) else { return }
        let span = min(dist(maxSeq, expected), 300)
        var missing: [UInt16] = []
        var s = expected
        for _ in 0..<span {
            if buffer[s] == nil, !nacked.contains(s) { missing.append(s) }
            s = s &+ 1
        }
        guard !missing.isEmpty else { return }
        for m in missing { nacked.insert(m) }
        if nacked.count > 2000 { nacked = Set(missing) }
        var fci: [UInt8] = []
        var i = 0
        while i < missing.count {
            let pid = missing[i]
            var blp: UInt16 = 0
            var j = i + 1
            while j < missing.count {
                let d = dist(missing[j], pid)
                guard d >= 1 && d <= 16 else { break }
                blp |= 1 << UInt16(d - 1)
                j += 1
            }
            fci += [UInt8(pid >> 8), UInt8(pid & 0xFF), UInt8(blp >> 8), UInt8(blp & 0xFF)]
            i = j
        }
        sendFeedback(pt: 205, fmt: 1, media: bufferSsrc, fci: fci)
        stats.nack += missing.count
    }

    // MARK: RTCP (запросы серверу)

    private func requestKeyframe(_ media: UInt32, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPli) > 0.5 else { return }
        lastPli = now
        sendFeedback(pt: 206, fmt: 1, media: media, fci: [])
        stats.pli += 1
    }

    /// RTCP обратной связи: заголовок и ssrc отправителя остаются открытыми (AAD), остальное шифруется.
    private func sendFeedback(pt: UInt8, fmt: UInt8, media: UInt32, fci: [UInt8]) {
        let words = (12 + fci.count) / 4 - 1
        var header: [UInt8] = [0x80 | fmt, pt, UInt8(words >> 8), UInt8(words & 0xFF)]
        header += [UInt8(ownSsrc >> 24), UInt8((ownSsrc >> 16) & 0xFF), UInt8((ownSsrc >> 8) & 0xFF), UInt8(ownSsrc & 0xFF)]
        var body: [UInt8] = [UInt8(media >> 24), UInt8((media >> 16) & 0xFF), UInt8((media >> 8) & 0xFF), UInt8(media & 0xFF)]
        body += fci

        let counter = rtcpNonce
        rtcpNonce &+= 1
        let nonce4: [UInt8] = [UInt8(counter >> 24), UInt8((counter >> 16) & 0xFF), UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)]
        var nonceData = Data(nonce4)
        nonceData.append(Data(count: 8))
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.seal(Data(body), using: key, nonce: nonce, authenticating: Data(header)) else { return }
        var packet = Data(header)
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        packet.append(contentsOf: nonce4)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: Сборка H264 из RTP (RFC 6184)

    private func resetFrame() {
        curTs = nil
        nals = []
        fu = nil
        frameBroken = false
    }

    private func depacketize(_ pkt: Pkt) {
        if curTs != pkt.ts {
            if curTs != nil { finishFrame() }
            curTs = pkt.ts
            nals = []
            fu = nil
        }
        let p = pkt.payload
        if !p.isEmpty {
            switch p[0] & 0x1F {
            case 1...23:
                nals.append(Data(p))
            case 24:
                var i = 1
                while i + 2 <= p.count {
                    let size = Int(p[i]) << 8 | Int(p[i + 1])
                    i += 2
                    guard size > 0, i + size <= p.count else { break }
                    nals.append(Data(p[i..<(i + size)]))
                    i += size
                }
            case 28:
                if p.count > 2 {
                    let indicator = p[0]
                    let header = p[1]
                    if (header & 0x80) != 0 {
                        var d = Data([(indicator & 0xE0) | (header & 0x1F)])
                        d.append(contentsOf: p[2...])
                        fu = d
                    } else if fu != nil {
                        fu?.append(contentsOf: p[2...])
                    } else {
                        frameBroken = true
                    }
                    if (header & 0x40) != 0, let f = fu {
                        nals.append(f)
                        fu = nil
                    }
                }
            default:
                break
            }
        }
        if pkt.marker {
            finishFrame()
            curTs = nil
        }
    }

    private func finishFrame() {
        defer {
            nals = []
            fu = nil
            frameBroken = false
        }
        guard !nals.isEmpty else { return }
        stats.frames += 1
        if frameBroken {
            waitingKeyframe = true
            stats.dropped += 1
            return
        }
        guard let user = videoSsrcs[bufferSsrc] else { return }
        var frame = H264AnnexB.join(nals)
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

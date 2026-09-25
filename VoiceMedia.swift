import Foundation
import Network
import CryptoKit
import AVFoundation
#if canImport(YbridOpus)
import YbridOpus
#endif

// MARK: - Opus

/// Декодер Opus (48 кГц, стерео) поверх libopus из пакета YbridOpus.
final class OpusDecoderBox {
    #if canImport(YbridOpus)
    private var dec: OpaquePointer?

    init?() {
        var err: Int32 = 0
        guard let d = opus_decoder_create(48000, 2, &err), err == 0 else { return nil }
        dec = d
    }

    deinit {
        if let d = dec { opus_decoder_destroy(d) }
    }

    /// Возвращает интерлейвленные стерео-сэмплы и количество кадров.
    func decode(_ data: Data) -> (samples: [Float], frames: Int)? {
        guard let d = dec, !data.isEmpty else { return nil }
        let maxFrames = 5760
        var pcm = [Float](repeating: 0, count: maxFrames * 2)
        let n: Int32 = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            pcm.withUnsafeMutableBufferPointer { out -> Int32 in
                opus_decode_float(d, raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), out.baseAddress!, Int32(maxFrames), 0)
            }
        }
        guard n > 0 else { return nil }
        return (Array(pcm[0..<(Int(n) * 2)]), Int(n))
    }
    #else
    init?() { return nil }
    func decode(_ data: Data) -> (samples: [Float], frames: Int)? { return nil }
    #endif
}

/// Кодировщик Opus для микрофона: 48 кГц, mono, кадры по 20 мс, режим VOIP.
final class OpusEncoderBox {
    #if canImport(YbridOpus)
    private var enc: OpaquePointer?

    init?() {
        var err: Int32 = 0
        // 2048 = OPUS_APPLICATION_VOIP
        guard let e = opus_encoder_create(48000, 1, 2048, &err), err == 0 else { return nil }
        enc = e
    }

    deinit {
        if let e = enc { opus_encoder_destroy(e) }
    }

    func encode(_ pcm: [Float]) -> Data? {
        guard let e = enc, pcm.count == 960 else { return nil }
        var out = [UInt8](repeating: 0, count: 1500)
        let n: Int32 = pcm.withUnsafeBufferPointer { p -> Int32 in
            out.withUnsafeMutableBufferPointer { o -> Int32 in
                opus_encode_float(e, p.baseAddress!, 960, o.baseAddress!, Int32(o.count))
            }
        }
        guard n > 0 else { return nil }
        return Data(out.prefix(Int(n)))
    }
    #else
    init?() { return nil }
    func encode(_ pcm: [Float]) -> Data? { return nil }
    #endif
}

// MARK: - Голосовые медиа-потоки

/// UDP <-> микрофон и динамик:
/// приём: UDP -> транспортная расшифровка (AES-256-GCM) -> DAVE -> Opus -> динамик;
/// отправка: микрофон -> Opus -> DAVE -> транспортное шифрование -> UDP.
final class VoiceMedia {
    private let connection: NWConnection
    private let key: SymmetricKey
    private let ssrc: UInt32
    private let dave: DaveSession?
    private let audio: VoiceAudio
    private let micAllowed: Bool
    private let queue = DispatchQueue(label: "voice.media")

    // Приём
    private var decoders: [UInt32: OpusDecoderBox] = [:]
    private var ssrcToUser: [UInt32: String] = [:]
    private var lastAudioReport: [String: Date] = [:]
    private var stopped = false

    // Отправка
    private var encoder: OpusEncoderBox?
    private var rtpSeq = UInt16.random(in: 0...UInt16.max)
    private var rtpTimestamp = UInt32.random(in: 0...UInt32.max)
    private var nonceCounter: UInt32 = 0

    // Видео (камера): своя нумерация пакетов, свой ssrc, свой payload type.
    private var videoSsrc: UInt32 = 0
    var videoPayloadType: UInt8 = 101
    private var videoRtpSeq = UInt16.random(in: 0...UInt16.max)
    private var videoNonceCounter: UInt32 = 0
    private static let rtpMaxPayload = 1100 // с запасом под заголовок/шифр-тег/nonce, не бьёт MTU

    private var muted = false
    private var speakingNow = false
    private var hangover = 0
    private var levelTick = 0

    private struct Stats: Equatable {
        var received = 0
        var transportFail = 0
        var unknownSsrc = 0
        var daveFail = 0
        var opusFail = 0
        var played = 0
        var sent = 0
        var encryptFail = 0
        var udpOut = 0
        var udpFail = 0
        var udpBytes = 0
    }
    private var stats = Stats()
    private var lastReported = Stats()
    private var timer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var keepaliveCounter: UInt64 = 0
    private var otherPackets: [String: Int] = [:]
    private var otherBytes: [String: Int] = [:]
    private var seenVideoPayloadTypes = Set<Int>()
    private var lastOtherLogged = ""
    private var firstTransportFailLogged = false
    private var firstDaveFailLogged = false
    private var firstEncryptFailLogged = false

    var log: ((String) -> Void)?
    /// Распознавание речи (необязательно) и наш id для подписи собственной речи.
    var transcriber: VoiceTranscriber?
    var ownUserId = ""
    /// Пришёл звук от пользователя (не чаще 10 раз в секунду на пользователя).
    var onAudio: ((String) -> Void)?
    /// Мы начали или закончили говорить.
    var onLocalSpeaking: ((Bool) -> Void)?
    /// Уровень микрофона в дБ (примерно 10 раз в секунду).
    var onMicLevel: ((Float) -> Void)?
    /// Отправка op 5 (Speaking) в голосовой шлюз.
    var sendSpeaking: ((Bool) -> Void)?
    /// Порог активации микрофона, дБ.
    var vadThresholdDb: () -> Double = { -45 }

    init(connection: NWConnection, secretKey: Data, ssrc: UInt32, dave: DaveSession?, audio: VoiceAudio, micAllowed: Bool) {
        self.connection = connection
        self.key = SymmetricKey(data: secretKey)
        self.ssrc = ssrc
        self.dave = dave
        self.audio = audio
        self.micAllowed = micAllowed
    }

    func start() {
        encoder = OpusEncoderBox()
        if micAllowed && encoder == nil {
            log?("Звук: кодировщик Opus недоступен, микрофон работать не будет")
        }
        audio.log = { [weak self] s in self?.log?(s) }
        audio.onMicFrame = { [weak self] frame in
            self?.queue.async { self?.handleMicFrame(frame) }
        }
        audio.start(useMic: micAllowed)

        receiveLoop()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.reportStats() }
        t.resume()
        timer = t

        // Раз в несколько секунд шлём keepalive по UDP: поддерживает соответствие в NAT/туннеле.
        let k = DispatchSource.makeTimerSource(queue: queue)
        k.schedule(deadline: .now() + 1, repeating: 4)
        k.setEventHandler { [weak self] in self?.sendKeepalive() }
        k.resume()
        keepaliveTimer = k
    }

    private func sendKeepalive() {
        var counter = keepaliveCounter.bigEndian
        keepaliveCounter &+= 1
        let data = Data(bytes: &counter, count: 8)
        udpSend(data)
    }

    /// Единая точка отправки в сеть — считает, сколько реально ушло и не вернула ли сеть ошибку.
    /// Так видно, доходит ли трафик до сервера, даже когда в канале никого нет.
    private func udpSend(_ data: Data) {
        let n = data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                if error == nil {
                    self.stats.udpOut += 1
                    self.stats.udpBytes += n
                } else {
                    self.stats.udpFail += 1
                }
            }
        })
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        audio.onMicFrame = nil
        audio.stop()
    }

    func setMuted(_ m: Bool) {
        queue.async {
            self.muted = m
            if m && self.speakingNow { self.finishSpeaking() }
        }
    }

    func setSsrc(_ ssrc: UInt32, user: String) {
        queue.async { self.ssrcToUser[ssrc] = user }
    }

    func removeUser(_ user: String) {
        queue.async {
            for (s, u) in self.ssrcToUser where u == user {
                self.ssrcToUser[s] = nil
                self.decoders[s] = nil
            }
        }
    }

    // MARK: Приём

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.queue.async { self.handlePacket(data) }
            }
            if error == nil {
                self.receiveLoop()
            } else {
                self.log?("UDP: приём остановлен (\(error?.localizedDescription ?? "?"))")
            }
        }
    }

    private func reportStats() {
        if !otherPackets.isEmpty {
            let text = otherPackets.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value) шт, \(otherBytes[$0.key] ?? 0) байт" }
                .joined(separator: ", ")
            if text != lastOtherLogged {
                lastOtherLogged = text
                log?("Прочие RTP-пакеты (возможно, видео): \(text)")
            }
        }
        guard stats != lastReported else { return }
        lastReported = stats
        log?("Звук: принято \(stats.received), проиграно \(stats.played), отправлено \(stats.sent). Ошибки: транспорт \(stats.transportFail), SSRC \(stats.unknownSsrc), DAVE \(stats.daveFail), Opus \(stats.opusFail), шифрование \(stats.encryptFail)")
        log?("Сеть UDP: ушло в сеть \(stats.udpOut) пакетов (\(stats.udpBytes) байт), ошибок отправки \(stats.udpFail). Если больше 0 — трафик до сервера идёт")
    }

    private func handlePacket(_ packet: Data) {
        let bytes = [UInt8](packet)
        // RTCP и служебные пакеты пропускаем
        if bytes.count >= 2, bytes[1] >= 192, bytes[1] <= 223 { return }

        stats.received += 1
        guard let (packetSsrc, packetTs, payload) = openTransport(bytes) else {
            stats.transportFail += 1
            if !firstTransportFailLogged {
                firstTransportFailLogged = true
                let head = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
                log?("Звук: транспортная расшифровка не удалась (\(bytes.count) байт, начало \(head))")
            }
            return
        }
        guard let user = ssrcToUser[packetSsrc] else {
            stats.unknownSsrc += 1
            let pt = bytes.count > 1 ? Int(bytes[1] & 0x7F) : -1
            let key = "pt\(pt) ssrc\(packetSsrc)"
            otherPackets[key, default: 0] += 1
            otherBytes[key, default: 0] += bytes.count
            // Первый раз, когда видим чужой поток похожий на видео (наш заявленный H264 — payload type 101),
            // сразу пишем отдельную заметную строку, не дожидаясь периодической сводки раз в 3 секунды.
            if !seenVideoPayloadTypes.contains(pt) {
                seenVideoPayloadTypes.insert(pt)
                let head = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
                log?("[видео/демо] Первый пакет с неизвестным ssrc \(packetSsrc), payload type \(pt), размер \(bytes.count) байт, начало: \(head)")
            }
            return
        }
        // Пакет тишины от сервера: три байта F8 FF FE.
        if payload.count == 3, payload[payload.startIndex] == 0xF8 { return }

        var opus = payload
        if let dave {
            guard let dec = dave.decrypt(userId: user, frame: payload) else {
                stats.daveFail += 1
                if !firstDaveFailLogged {
                    firstDaveFailLogged = true
                    log?("Звук: DAVE не смог расшифровать кадр от \(user) (\(payload.count) байт)")
                }
                return
            }
            opus = dec
        }

        var decoder = decoders[packetSsrc]
        if decoder == nil {
            decoder = OpusDecoderBox()
            decoders[packetSsrc] = decoder
        }
        guard let d = decoder, let pcm = d.decode(opus) else {
            stats.opusFail += 1
            return
        }
        stats.played += 1
        audio.play(ssrc: packetSsrc, interleaved: pcm.samples, frames: pcm.frames, user: user)
        transcriber?.feed(userId: user, interleaved: pcm.samples, channels: 2, frames: pcm.frames, rtpTimestamp: packetTs)

        let now = Date()
        if now.timeIntervalSince(lastAudioReport[user] ?? .distantPast) > 0.1 {
            lastAudioReport[user] = now
            onAudio?(user)
        }
    }

    /// Транспортная расшифровка режима aead_aes256_gcm_rtpsize.
    /// Заголовок RTP (с CSRC и преамбулой расширения) идёт как AAD, в конце пакета 4 байта nonce, перед ними 16 байт тега.
    private func openTransport(_ bytes: [UInt8]) -> (UInt32, UInt32, Data)? {
        guard bytes.count >= 12 + 16 + 4 else { return nil }
        let b0 = bytes[0]
        guard b0 >> 6 == 2 else { return nil }

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

        var src: UInt32 = 0
        for i in 8..<12 {
            src = (src << 8) | UInt32(bytes[i])
        }
        var rtpTs: UInt32 = 0
        for i in 4..<8 {
            rtpTs = (rtpTs << 8) | UInt32(bytes[i])
        }
        let tagStart = bytes.count - 4 - 16
        let cipher = Data(bytes[headerLen..<tagStart])
        let tag = Data(bytes[tagStart..<(bytes.count - 4)])
        var nonceData = Data(bytes[(bytes.count - 4)...])
        nonceData.append(Data(count: 8))
        let aad = Data(bytes[0..<headerLen])

        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad) else { return nil }

        var payload = plain
        if hasExtension {
            let n = extWords * 4
            guard payload.count >= n else { return nil }
            payload = Data(payload.dropFirst(n))
        }
        return (src, rtpTs, payload)
    }

    // MARK: Отправка

    private func handleMicFrame(_ frame: [Float]) {
        let ts = rtpTimestamp
        rtpTimestamp = rtpTimestamp &+ 960

        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -120

        levelTick += 1
        if levelTick >= 5 {
            levelTick = 0
            onMicLevel?(db)
        }

        guard encoder != nil else { return }
        if muted {
            if speakingNow { finishSpeaking() }
            return
        }

        if Double(db) > vadThresholdDb() {
            hangover = 15
            if !speakingNow { startSpeaking() }
        } else if hangover > 0 {
            hangover -= 1
        } else {
            if speakingNow { finishSpeaking() }
            return
        }
        guard speakingNow else { return }
        transcriber?.feed(userId: ownUserId, interleaved: frame, channels: 1, frames: frame.count, rtpTimestamp: ts)
        sendFrame(frame, timestamp: ts)
    }

    private func startSpeaking() {
        speakingNow = true
        sendSpeaking?(true)
        onLocalSpeaking?(true)
    }

    private func finishSpeaking() {
        speakingNow = false
        // Пять кадров тишины, чтобы у собеседников не было артефактов интерполяции Opus.
        for _ in 0..<5 {
            let ts = rtpTimestamp
            rtpTimestamp = rtpTimestamp &+ 960
            sendOpus(Data([0xF8, 0xFF, 0xFE]), timestamp: ts)
        }
        sendSpeaking?(false)
        onLocalSpeaking?(false)
    }

    // MARK: - Отправка видео (камера)

    func setVideoSsrc(_ s: UInt32) {
        queue.async { self.videoSsrc = s }
    }

    /// Отправить один кадр H264: каждый NAL-юнит отдельно, крупные — разбиваются на FU-A.
    /// RTP-заголовок шифруется тем же способом, что и звук (через DAVE, если он есть).
    func sendVideoFrame(nalUnits: [Data], timestamp: UInt32) {
        queue.async { [weak self] in
            guard let self, self.videoSsrc != 0 else { return }
            // DAVE шифрует кадр целиком (в формате Annex-B, со стартовыми кодами), а не каждый
            // NAL или RTP-пакет отдельно. Потом кадр снова делим на NAL-юниты и пакуем в RTP.
            var frame = H264AnnexB.join(nalUnits)
            if let dave = self.dave {
                guard let enc = dave.encryptVideo(frame: frame, ssrc: self.videoSsrc) else {
                    self.stats.encryptFail += 1
                    return
                }
                frame = enc
            }
            let units = H264AnnexB.split(frame)
            for (i, nal) in units.enumerated() {
                self.sendNAL(nal, timestamp: timestamp, markLast: i == units.count - 1)
            }
        }
    }

    private func sendNAL(_ nal: Data, timestamp: UInt32, markLast: Bool) {
        guard !nal.isEmpty else { return }
        if nal.count <= VoiceMedia.rtpMaxPayload {
            sendVideoPacket(nal, timestamp: timestamp, marker: markLast)
            return
        }
        // FU-A: делим NAL на куски, первый байт исходного NAL несёт тип+NRI, дальше идут
        // индикатор-байт (тип 28 = FU-A) и заголовок фрагмента (start/end/тип).
        let header = nal[nal.startIndex]
        let nri = header & 0x60
        let type = header & 0x1F
        let payload = nal.dropFirst()
        var offset = payload.startIndex
        var first = true
        while offset < payload.endIndex {
            let chunkEnd = payload.index(offset, offsetBy: VoiceMedia.rtpMaxPayload - 2, limitedBy: payload.endIndex) ?? payload.endIndex
            let isLastChunk = chunkEnd == payload.endIndex
            var packet = Data()
            packet.append(nri | 28) // индикатор: FU-A (тип 28) с NRI исходного NAL
            var fuHeader: UInt8 = type
            if first { fuHeader |= 0x80 }
            if isLastChunk { fuHeader |= 0x40 }
            packet.append(fuHeader)
            packet.append(payload[offset..<chunkEnd])
            sendVideoPacket(packet, timestamp: timestamp, marker: isLastChunk && markLast)
            offset = chunkEnd
            first = false
        }
    }

    private func sendVideoPacket(_ payloadIn: Data, timestamp: UInt32, marker: Bool) {
        let payload = payloadIn

        var header = [UInt8](repeating: 0, count: 12)
        header[0] = 0x80
        header[1] = (marker ? 0x80 : 0x00) | (videoPayloadType & 0x7F)
        header[2] = UInt8(videoRtpSeq >> 8)
        header[3] = UInt8(videoRtpSeq & 0xFF)
        header[4] = UInt8((timestamp >> 24) & 0xFF)
        header[5] = UInt8((timestamp >> 16) & 0xFF)
        header[6] = UInt8((timestamp >> 8) & 0xFF)
        header[7] = UInt8(timestamp & 0xFF)
        header[8] = UInt8((videoSsrc >> 24) & 0xFF)
        header[9] = UInt8((videoSsrc >> 16) & 0xFF)
        header[10] = UInt8((videoSsrc >> 8) & 0xFF)
        header[11] = UInt8(videoSsrc & 0xFF)
        videoRtpSeq = videoRtpSeq &+ 1

        let counter = videoNonceCounter
        videoNonceCounter = videoNonceCounter &+ 1
        let nonce4: [UInt8] = [
            UInt8((counter >> 24) & 0xFF), UInt8((counter >> 16) & 0xFF),
            UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)
        ]
        var nonceData = Data(nonce4)
        nonceData.append(Data(count: 8))

        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: Data(header)) else { return }

        var packet = Data(header)
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        packet.append(contentsOf: nonce4)
        udpSend(packet)
        stats.sent += 1
    }

    private func sendFrame(_ pcm: [Float], timestamp: UInt32) {
        guard let opus = encoder?.encode(pcm) else { return }
        sendOpus(opus, timestamp: timestamp)
    }

    private func sendOpus(_ opus: Data, timestamp: UInt32) {
        var payload = opus
        if let dave {
            guard let enc = dave.encrypt(frame: opus, ssrc: ssrc) else {
                stats.encryptFail += 1
                if !firstEncryptFailLogged {
                    firstEncryptFailLogged = true
                    log?("Звук: DAVE не смог зашифровать кадр (ключ ещё не готов?)")
                }
                return
            }
            payload = enc
        }

        var header = [UInt8](repeating: 0, count: 12)
        header[0] = 0x80
        header[1] = 0x78
        header[2] = UInt8(rtpSeq >> 8)
        header[3] = UInt8(rtpSeq & 0xFF)
        header[4] = UInt8((timestamp >> 24) & 0xFF)
        header[5] = UInt8((timestamp >> 16) & 0xFF)
        header[6] = UInt8((timestamp >> 8) & 0xFF)
        header[7] = UInt8(timestamp & 0xFF)
        header[8] = UInt8((ssrc >> 24) & 0xFF)
        header[9] = UInt8((ssrc >> 16) & 0xFF)
        header[10] = UInt8((ssrc >> 8) & 0xFF)
        header[11] = UInt8(ssrc & 0xFF)
        rtpSeq = rtpSeq &+ 1

        let counter = nonceCounter
        nonceCounter = nonceCounter &+ 1
        let nonce4: [UInt8] = [
            UInt8((counter >> 24) & 0xFF), UInt8((counter >> 16) & 0xFF),
            UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)
        ]
        var nonceData = Data(nonce4)
        nonceData.append(Data(count: 8))

        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: Data(header)) else { return }

        var packet = Data(header)
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        packet.append(contentsOf: nonce4)
        udpSend(packet)
        stats.sent += 1
    }
}

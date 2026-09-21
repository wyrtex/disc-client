import Foundation
import SwiftUI
import Translation
import NaturalLanguage

// MARK: - Настройки перевода канала

struct ChannelTranslateSettings: Codable, Equatable {
    var incomingEnabled = false
    var count = 20
    var incomingTarget = "ru"
    var outgoingEnabled = false
    var outgoingLang = "en"
}

struct LangPair: Hashable, Identifiable {
    let source: String
    let target: String
    var id: String { source + ">" + target }
}

struct TranslatedText {
    let text: String
    let sourceCode: String
}

struct Language: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    static let all: [Language] = [
        Language(code: "ru", name: "Русский"), Language(code: "en", name: "English"),
        Language(code: "es", name: "Español"), Language(code: "pt", name: "Português"),
        Language(code: "fr", name: "Français"), Language(code: "de", name: "Deutsch"),
        Language(code: "it", name: "Italiano"), Language(code: "pl", name: "Polski"),
        Language(code: "uk", name: "Українська"), Language(code: "tr", name: "Türkçe"),
        Language(code: "nl", name: "Nederlands"), Language(code: "id", name: "Indonesia"),
        Language(code: "vi", name: "Tiếng Việt"), Language(code: "th", name: "ไทย"),
        Language(code: "ar", name: "العربية"), Language(code: "hi", name: "हिन्दी"),
        Language(code: "ja", name: "日本語"), Language(code: "ko", name: "한국어"),
        Language(code: "zh-Hans", name: "中文")
    ]

    static func name(_ code: String) -> String {
        if let n = all.first(where: { $0.code == code })?.name { return n }
        let n = Locale(identifier: "ru").localizedString(forLanguageCode: code) ?? code
        return n.prefix(1).uppercased() + n.dropFirst()
    }
}

// MARK: - Защита служебных кусков текста

/// Упоминания, эмодзи сервера, ссылки и код не переводим: режем текст на куски и переводим только обычный текст.
enum TextProtect {
    enum Seg {
        case text(String)
        case keep(String)

        var raw: String {
            switch self {
            case .text(let s): return s
            case .keep(let s): return s
            }
        }
    }

    private static let regex = try? NSRegularExpression(
        pattern: "<a?:\\w+:\\d+>|<@[!&]?\\d+>|<#\\d+>|<t:\\d+(?::[a-zA-Z])?>|https?://\\S+|```[\\s\\S]*?```|`[^`\\n]+`"
    )

    static func split(_ s: String) -> [Seg] {
        guard let regex else { return [.text(s)] }
        let ns = s as NSString
        var out: [Seg] = []
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last))))
            }
            out.append(.keep(ns.substring(with: m.range)))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }

    static func hasLetters(_ s: String) -> Bool {
        s.contains { $0.isLetter }
    }

    /// Определяет язык обычного текста (без ссылок и упоминаний).
    static func detect(_ segs: [Seg]) -> String? {
        var parts: [String] = []
        for seg in segs {
            if case .text(let s) = seg { parts.append(s) }
        }
        let clean = parts.joined(separator: " ")
        guard hasLetters(clean) else { return nil }
        let r = NLLanguageRecognizer()
        // Определяем язык только среди тех, что есть в списке. Иначе короткие фразы
        // «превращаются» в норвежский, датский и прочее, чего в чате нет.
        r.languageConstraints = Languages.all.map { NLLanguage(rawValue: $0.code) }
        r.processString(clean)
        let hyp = r.languageHypotheses(withMaximum: 3)
        if let best = hyp.max(by: { $0.value < $1.value }), best.value >= 0.5 {
            return best.key.rawValue
        }
        // Короткие фразы вроде «hru?»: если это латиница без диакритики, считаем английским.
        if clean.unicodeScalars.allSatisfy({ $0.isASCII }) { return "en" }
        return nil
    }
}

// MARK: - Стиль: без заглавной и без точки, если их не было в оригинале

enum StyleFix {
    /// Для куска текста: сохраняет пробелы по краям оригинала и приводит перевод к его стилю.
    static func applySegment(source: String, translated: String) -> String {
        let lead = String(source.prefix(while: { $0.isWhitespace }))
        let trail = String(source.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        return lead + apply(source: s, translated: t) + trail
    }

    static func apply(source: String, translated: String) -> String {
        let sr = sentenceRanges(source)
        let tr = sentenceRanges(translated)
        if sr.count > 1, sr.count == tr.count {
            var result = ""
            var cursor = translated.startIndex
            for i in 0..<tr.count {
                result.append(contentsOf: translated[cursor..<tr[i].lowerBound])
                result.append(contentsOf: fix(src: String(source[sr[i]]), dst: String(translated[tr[i]])))
                cursor = tr[i].upperBound
            }
            result.append(contentsOf: translated[cursor...])
            return result
        }
        return fix(src: source, dst: translated)
    }

    private static func sentenceRanges(_ s: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = s
        var out: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            out.append(range)
            return true
        }
        return out
    }

    private static func fix(src: String, dst: String) -> String {
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return dst }

        let trailWS = String(dst.reversed().prefix(while: { $0.isWhitespace }).reversed())
        var core = String(dst.dropLast(trailWS.count))

        // Заглавная буква: если в оригинале первая буква не заглавная, в переводе тоже не будет.
        if let first = s.first(where: { $0.isLetter }), !first.isUppercase {
            core = lowercaseFirst(core)
        }
        // Точка в конце: если в оригинале её нет, убираем. Остальные знаки не трогаем.
        if let last = s.last, last != ".", last != "。" {
            if core.hasSuffix(".") && !core.hasSuffix("..") {
                core.removeLast()
            }
        }
        return core + trailWS
    }

    private static func lowercaseFirst(_ s: String) -> String {
        guard let idx = s.firstIndex(where: { $0.isLetter }) else { return s }
        var end = idx
        while end < s.endIndex {
            let ch = s[end]
            if ch.isWhitespace { break }
            if ch.isPunctuation && ch != "'" && ch != "’" { break }
            end = s.index(after: end)
        }
        let word = String(s[idx..<end])
        // Аббревиатуры (OK, США) и английское «I» не трогаем.
        if word.count > 1, word == word.uppercased() { return s }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return s }
        var out = s
        out.replaceSubrange(idx...idx, with: String(s[idx]).lowercased())
        return out
    }
}

// MARK: - Перевод

/// Очередь переводов поверх системного Translation. Сессия доступна только внутри `.translationTask`,
/// поэтому задания ставятся в очередь, а `run` выполняет их по одному.
@MainActor
final class Translator: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var incoming: [String: TranslatedText] = [:]
    /// Пары языков, для которых не хватает пакета. Скачиваются только по кнопке.
    @Published var pending: [LangPair] = []
    @Published var settings: [String: ChannelTranslateSettings] = [:] {
        didSet { save() }
    }

    private var skipped: Set<String> = []
    private var queue: [Job] = []
    private var current: Job?
    private var running: Job?

    final class Job {
        let source: Locale.Language
        let target: Locale.Language
        let texts: [String]
        let prepareOnly: Bool
        var startedAt = Date()
        var continuation: CheckedContinuation<[String?], Never>?

        init(source: Locale.Language, target: Locale.Language, texts: [String], prepareOnly: Bool = false) {
            self.source = source
            self.target = target
            self.texts = texts
            self.prepareOnly = prepareOnly
        }

        func finish(_ results: [String?]) {
            continuation?.resume(returning: results)
            continuation = nil
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "translateSettings"),
           let s = try? JSONDecoder().decode([String: ChannelTranslateSettings].self, from: data) {
            settings = s
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "translateSettings")
        }
    }

    func binding(for channelId: String) -> Binding<ChannelTranslateSettings> {
        Binding(
            get: { self.settings[channelId] ?? ChannelTranslateSettings() },
            set: { self.settings[channelId] = $0 }
        )
    }

    func cacheKey(_ m: Message, _ target: String) -> String {
        "\(m.id)|\(target)|\(m.content.hashValue)"
    }

    func resetSkips() {
        skipped.removeAll()
    }

    // MARK: Входящие

    func translateIncoming(_ msgs: [Message], target: String) async {
        struct Item {
            let key: String
            let segs: [TextProtect.Seg]
        }
        var groups: [String: [Item]] = [:]

        for m in msgs {
            let key = cacheKey(m, target)
            if incoming[key] != nil || skipped.contains(key) { continue }
            let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let segs = TextProtect.split(text)
            guard !text.isEmpty, let lang = TextProtect.detect(segs) else {
                skipped.insert(key)
                continue
            }
            if lang == target || lang.hasPrefix(target + "-") {
                skipped.insert(key)
                continue
            }
            groups[lang, default: []].append(Item(key: key, segs: segs))
        }

        for (lang, items) in groups {
            let results = await translateItems(items.map { $0.segs }, from: lang, to: target)
            for (i, item) in items.enumerated() {
                if let text = results[i] {
                    incoming[item.key] = TranslatedText(text: text, sourceCode: lang)
                } else {
                    skipped.insert(item.key)
                }
            }
        }
    }

    // MARK: Исходящие

    /// Возвращает перевод (в стиле оригинала) или nil, если перевести не удалось.
    func translateOutgoing(_ text: String, to target: String) async -> String? {
        let segs = TextProtect.split(text)
        guard TextProtect.hasLetters(text) else { return text }
        let source = TextProtect.detect(segs) ?? "ru"
        if source == target || source.hasPrefix(target + "-") { return text }
        let results = await translateItems([segs], from: source, to: target, timeout: 90)
        return results.first ?? nil
    }

    // MARK: Общая часть

    private func translateItems(_ items: [[TextProtect.Seg]], from lang: String, to target: String, timeout: Double = 0) async -> [String?] {
        var texts: [String] = []
        var map: [(item: Int, seg: Int)] = []
        for (i, segs) in items.enumerated() {
            for (j, seg) in segs.enumerated() {
                if case .text(let s) = seg, TextProtect.hasLetters(s) {
                    texts.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    map.append((item: i, seg: j))
                }
            }
        }

        let results = await translate(texts, from: lang, to: target, timeout: timeout)

        var out: [[String]] = []
        for segs in items {
            out.append(segs.map { seg in seg.raw })
        }
        var failed = Set<Int>()
        for (k, m) in map.enumerated() {
            guard k < results.count, let tr = results[k], !tr.isEmpty else {
                failed.insert(m.item)
                continue
            }
            out[m.item][m.seg] = StyleFix.applySegment(source: items[m.item][m.seg].raw, translated: tr)
        }

        var final: [String?] = []
        for (i, parts) in out.enumerated() {
            final.append(failed.contains(i) ? nil : parts.joined())
        }
        return final
    }

    private func translate(_ texts: [String], from source: String, to target: String, timeout: Double = 0) async -> [String?] {
        guard !texts.isEmpty else { return [] }
        let src = Locale.Language(identifier: source)
        let dst = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: src, to: dst)
        switch status {
        case .installed:
            break
        case .supported:
            // Пакет не скачан: ничего не запрашиваем у системы, только запоминаем, чтобы предложить скачать.
            notePending(source, target)
            return Array(repeating: nil, count: texts.count)
        default:
            return Array(repeating: nil, count: texts.count)
        }
        // Зависшее задание (например, окно скачивания языков закрыли) не должно блокировать очередь навсегда.
        if let c = current, Date().timeIntervalSince(c.startedAt) > 120 {
            finishCurrent(c, nil)
        }
        return await withCheckedContinuation { cont in
            let job = Job(source: src, target: dst, texts: texts)
            job.continuation = cont
            queue.append(job)
            if timeout > 0 {
                Task { [weak job] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let job else { return }
                    job.finish(Array(repeating: nil, count: job.texts.count))
                }
            }
            pump()
        }
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        job.startedAt = Date()
        let newConfig = TranslationSession.Configuration(source: job.source, target: job.target)
        if configuration == newConfig {
            configuration?.invalidate()
        } else {
            configuration = newConfig
        }
    }

    private func notePending(_ source: String, _ target: String) {
        let p = LangPair(source: source, target: target)
        if !pending.contains(p) { pending.append(p) }
    }

    /// Скачивание языковых пакетов пары (система покажет своё окно).
    func prepare(_ pair: LangPair) async {
        let job = Job(
            source: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target),
            texts: [],
            prepareOnly: true
        )
        _ = await withCheckedContinuation { (cont: CheckedContinuation<[String?], Never>) in
            job.continuation = cont
            queue.append(job)
            pump()
        }
        let status = await LanguageAvailability().status(from: job.source, to: job.target)
        if status == .installed {
            pending.removeAll { $0 == pair }
        }
        resetSkips()
    }

    /// Перевод строки субтитров.
    func translateCaption(_ text: String, from source: String, to target: String) async -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TextProtect.hasLetters(t) else { return nil }
        if source == target || source.hasPrefix(target + "-") { return nil }
        let r = await translate([t], from: source, to: target, timeout: 25)
        return r.first ?? nil
    }

    /// Вызывается из `.translationTask`.
    func run(_ session: TranslationSession) async {
        guard let job = current, running !== job else { return }
        running = job
        if job.prepareOnly {
            do { try await session.prepareTranslation() } catch {}
            finishCurrent(job, [])
            return
        }
        var results = [String?](repeating: nil, count: job.texts.count)
        do {
            var requests: [TranslationSession.Request] = []
            for (i, t) in job.texts.enumerated() {
                requests.append(TranslationSession.Request(sourceText: t, clientIdentifier: String(i)))
            }
            let responses = try await session.translations(from: requests)
            for r in responses {
                if let id = r.clientIdentifier, let i = Int(id), i < results.count {
                    results[i] = r.targetText
                }
            }
        } catch {
            // Языки не скачаны или перевод отклонён: результаты остаются пустыми.
        }
        finishCurrent(job, results)
    }

    private func finishCurrent(_ job: Job, _ results: [String?]?) {
        job.finish(results ?? Array(repeating: nil, count: job.texts.count))
        if current === job { current = nil }
        if running === job { running = nil }
        pump()
    }
}

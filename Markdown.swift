import SwiftUI

// MARK: - Разбор блоков (как в Discord)

enum MDBlock {
    case paragraph(String)
    case heading(Int, String)
    case quote([MDBlock])
    case item(indent: Int, marker: String, text: String)
    case code(String)
    case subtext(String)
}

enum MarkdownParser {
    private static let headingRe = try? NSRegularExpression(pattern: "^(#{1,3})\\s+(.+)$")
    private static let subtextRe = try? NSRegularExpression(pattern: "^-#\\s+(.+)$")
    private static let bulletRe = try? NSRegularExpression(pattern: "^(\\s*)[-*]\\s+(.+)$")
    private static let numberRe = try? NSRegularExpression(pattern: "^(\\s*)(\\d{1,3})\\.\\s+(.+)$")

    private static func groups(_ re: NSRegularExpression?, _ line: String) -> [String]? {
        guard let re else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return out
    }

    static func blocks(_ raw: String, allowQuote: Bool = true) -> [MDBlock] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MDBlock] = []
        var para: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            para = []
        }
        func flushQuote() {
            if !quote.isEmpty {
                out.append(.quote(blocks(quote.joined(separator: "\n"), allowQuote: false)))
                quote = []
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Внутри блока кода
            if code != nil {
                if trimmed.hasPrefix("```") {
                    out.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushPara()
                flushQuote()
                let rest = String(trimmed.dropFirst(3))
                if rest.count > 3, rest.hasSuffix("```") {
                    out.append(.code(String(rest.dropLast(3))))
                } else {
                    code = []
                    // Первая строка после ``` может быть названием языка.
                    if !rest.isEmpty, rest.contains(" ") { code?.append(rest) }
                }
                continue
            }

            // Цитата на всё остальное сообщение
            if allowQuote, line.hasPrefix(">>>") {
                flushPara()
                flushQuote()
                var first = String(line.dropFirst(3))
                if first.hasPrefix(" ") { first.removeFirst() }
                let rest = ([first] + Array(lines[i...])).joined(separator: "\n")
                out.append(.quote(blocks(rest, allowQuote: false)))
                i = lines.count
                continue
            }

            // Обычная цитата
            if allowQuote, line.hasPrefix("> ") || line == ">" {
                flushPara()
                quote.append(line == ">" ? "" : String(line.dropFirst(2)))
                continue
            }
            flushQuote()

            if let g = groups(headingRe, line) {
                flushPara()
                out.append(.heading(g[0].count, g[1]))
                continue
            }
            if let g = groups(subtextRe, line) {
                flushPara()
                out.append(.subtext(g[0]))
                continue
            }
            if let g = groups(bulletRe, line) {
                flushPara()
                out.append(.item(indent: min(3, g[0].count / 2), marker: "•", text: g[1]))
                continue
            }
            if let g = groups(numberRe, line) {
                flushPara()
                out.append(.item(indent: min(3, g[0].count / 2), marker: g[1] + ".", text: g[2]))
                continue
            }
            para.append(line)
        }

        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara()
        flushQuote()
        return out
    }
}

// MARK: - Разметка внутри строки: **жирный**, *курсив*, __подчёркнутый__, ~~зачёркнутый~~, ||спойлер||, `код`

enum InlineStyler {
    private static let re = try? NSRegularExpression(
        pattern: "(`{1,2})([^`\\n]+?)\\1|\\|\\|([\\s\\S]+?)\\|\\||(?<!\\w)__([^_\\n][\\s\\S]*?)__(?!\\w)"
    )

    static func attributed(_ s: String, revealed: Bool) -> AttributedString {
        guard let re else { return plain(s) }
        let ns = s as NSString
        var out = AttributedString()
        var last = 0

        func text(_ m: NSTextCheckingResult, _ g: Int) -> String? {
            let r = m.range(at: g)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out += plain(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            if let code = text(m, 2) {
                var a = AttributedString(code)
                a.font = .system(size: 14, design: .monospaced)
                a.backgroundColor = Color.white.opacity(0.10)
                out += a
            } else if let spoiler = text(m, 3) {
                var a = attributed(spoiler, revealed: revealed)
                if revealed {
                    a.backgroundColor = Color.white.opacity(0.12)
                } else {
                    a.foregroundColor = Color(hex: 0x1E1F22)
                    a.backgroundColor = Color(hex: 0x1E1F22)
                }
                out += a
            } else if let under = text(m, 4) {
                var a = attributed(under, revealed: revealed)
                a.underlineStyle = .single
                out += a
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length {
            out += plain(ns.substring(from: last))
        }
        return out
    }

    /// Обычный markdown (жирный, курсив, зачёркнутый, ссылки). Голые ссылки делаем кликабельными.
    private static func plain(_ raw: String) -> AttributedString {
        let s = raw.replacingOccurrences(
            of: "(?<![\\(<\\[])https?://[^\\s<>\\)\\]]+",
            with: "[$0]($0)",
            options: .regularExpression
        )
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: options) { return a }
        return AttributedString(raw)
    }
}

// MARK: - Текст сообщения

private struct SpoilerTap: ViewModifier {
    let active: Bool
    @Binding var revealed: Bool

    func body(content: Content) -> some View {
        if active {
            content.onTapGesture { revealed.toggle() }
        } else {
            content
        }
    }
}

/// Текст сообщения: заголовки, цитаты, списки, код, форматирование строк, кастомные эмодзи,
/// упоминания (пользователи, роли цветом роли, каналы) и время.
struct RichText: View {
    let raw: String
    let mentions: [User]
    @EnvironmentObject var store: Store
    @Environment(\.currentGuildId) private var guildId
    @State private var images: [String: UIImage] = [:]
    @State private var revealed = false

    enum Token {
        case text(String)
        case emoji(id: String, name: String)
        case mention(kind: String, id: String)
        case time(seconds: Double, style: String)

        var isEmoji: Bool {
            if case .emoji = self { return true }
            return false
        }
    }

    private static let tokenRegex = try? NSRegularExpression(
        pattern: "<a?:(\\w+):(\\d+)>|<@!?(\\d+)>|<@&(\\d+)>|<#(\\d+)>|<t:(-?\\d+)(?::([a-zA-Z]))?>|@(everyone|here)\\b"
    )

    private static let placeholderRe = try? NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")

    static func tokenize(_ s: String) -> [Token] {
        guard let re = tokenRegex else { return [.text(s)] }
        let ns = s as NSString
        var out: [Token] = []
        var last = 0

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last))))
            }
            if let id = group(m, 2), let name = group(m, 1) {
                out.append(.emoji(id: id, name: name))
            } else if let id = group(m, 3) {
                out.append(.mention(kind: "u", id: id))
            } else if let id = group(m, 4) {
                out.append(.mention(kind: "r", id: id))
            } else if let id = group(m, 5) {
                out.append(.mention(kind: "c", id: id))
            } else if let t = group(m, 6), let secs = Double(t) {
                out.append(.time(seconds: secs, style: group(m, 7) ?? "f"))
            } else if let name = group(m, 8) {
                out.append(.mention(kind: "e", id: name))
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }

    private var jumbo: Bool {
        let t = RichText.tokenize(raw)
        let count = t.filter { $0.isEmoji }.count
        let onlyEmoji = t.allSatisfy { tok in
            switch tok {
            case .emoji: return true
            case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
        return count > 0 && count <= 6 && onlyEmoji
    }

    private var emojiSize: CGFloat { jumbo ? 44 : 22 }

    var body: some View {
        let blocks = MarkdownParser.blocks(raw)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                blockView(b)
            }
        }
        .foregroundStyle(Theme.normalText)
        .tint(Theme.link)
        .task(id: raw) {
            let size = emojiSize
            for case .emoji(let id, _) in RichText.tokenize(raw) where images[id] == nil {
                if let img = await ImageLoader.shared.emojiImage(id: id, points: size) {
                    images[id] = img
                }
            }
        }
        .modifier(SpoilerTap(active: raw.contains("||"), revealed: $revealed))
    }

    // MARK: Блоки

    @ViewBuilder
    private func blockView(_ b: MDBlock) -> some View {
        switch b {
        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: 0x4E5058))
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, ib in
                        simpleBlock(ib)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        default:
            simpleBlock(b)
        }
    }

    @ViewBuilder
    private func simpleBlock(_ b: MDBlock) -> some View {
        switch b {
        case .paragraph(let s):
            inline(s).font(.system(size: 16))
        case .heading(let level, let s):
            inline(s).font(.system(size: level == 1 ? 26 : (level == 2 ? 21 : 18), weight: .bold))
        case .item(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: 16))
                inline(text).font(.system(size: 16))
            }
            .padding(.leading, CGFloat(indent) * 14 + 4)
        case .code(let t):
            Text(t)
                .font(.system(size: 14, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0x1E1F22), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
        case .subtext(let s):
            inline(s)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        case .quote:
            EmptyView()
        }
    }

    // MARK: Строка

    /// Специальные куски (эмодзи, упоминания, время) заменяем метками, чтобы разметка вроде
    /// `**жирный <:эмодзи:> текст**` работала целиком, а потом подставляем их обратно.
    private func inline(_ s: String) -> Text {
        var processed = ""
        var tokens: [Token] = []
        for t in RichText.tokenize(s) {
            switch t {
            case .text(let str):
                processed += str
            default:
                processed += "\u{E000}\(tokens.count)\u{E001}"
                tokens.append(t)
            }
        }
        let attr = InlineStyler.attributed(processed, revealed: revealed)
        if tokens.isEmpty { return Text(attr) }

        var result = Text("")
        for run in attr.runs {
            let slice = AttributedString(attr[run.range])
            let str = String(slice.characters)
            guard str.contains("\u{E000}"), let re = RichText.placeholderRe else {
                result = result + Text(slice)
                continue
            }
            var cursor = str.startIndex
            for m in re.matches(in: str, range: NSRange(str.startIndex..., in: str)) {
                guard let r = Range(m.range, in: str) else { continue }
                if r.lowerBound > cursor {
                    result = result + Text(part(slice, str, cursor..<r.lowerBound))
                }
                if let ir = Range(m.range(at: 1), in: str), let idx = Int(str[ir]), idx < tokens.count {
                    result = result + tokenText(tokens[idx])
                }
                cursor = r.upperBound
            }
            if cursor < str.endIndex {
                result = result + Text(part(slice, str, cursor..<str.endIndex))
            }
        }
        return result
    }

    private func part(_ slice: AttributedString, _ str: String, _ range: Range<String.Index>) -> AttributedString {
        let a = str.distance(from: str.startIndex, to: range.lowerBound)
        let b = str.distance(from: str.startIndex, to: range.upperBound)
        let lo = slice.index(slice.startIndex, offsetByCharacters: a)
        let hi = slice.index(slice.startIndex, offsetByCharacters: b)
        return AttributedString(slice[lo..<hi])
    }

    // MARK: Упоминания и время

    private func roleColor(_ id: String) -> Color? {
        guard let gid = guildId,
              let c = store.guildRoles[gid]?.first(where: { $0.id == id })?.color, c > 0 else { return nil }
        return Color(hex: UInt32(c))
    }

    private func mentionName(kind: String, id: String) -> String {
        switch kind {
        case "u":
            if let u = mentions.first(where: { $0.id == id }) { return "@" + u.displayName }
            if let u = store.voiceUsers[id] { return "@" + u.displayName }
            if let me = store.me, me.id == id { return "@" + me.displayName }
            return "@пользователь"
        case "r":
            if let gid = guildId,
               let role = store.guildRoles[gid]?.first(where: { $0.id == id }) {
                return "@" + role.name
            }
            return "@роль"
        case "e":
            return "@" + id
        default:
            if let name = store.channelName(id) { return "#" + name }
            return "#канал"
        }
    }

    private func timeString(_ secs: Double, style: String) -> String {
        let d = Date(timeIntervalSince1970: secs)
        if style == "R" {
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: "ru_RU")
            return f.localizedString(for: d, relativeTo: Date())
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        switch style {
        case "t": f.dateStyle = .none; f.timeStyle = .short
        case "T": f.dateStyle = .none; f.timeStyle = .medium
        case "d": f.dateStyle = .short; f.timeStyle = .none
        case "D": f.dateStyle = .long; f.timeStyle = .none
        case "F": f.dateStyle = .full; f.timeStyle = .short
        default: f.dateStyle = .long; f.timeStyle = .short
        }
        return f.string(from: d)
    }

    private func tokenText(_ t: Token) -> Text {
        switch t {
        case .text(let s):
            return Text(s)
        case .emoji(let id, let name):
            if let img = images[id] { return Text(Image(uiImage: img)) }
            return Text(":\(name):")
        case .mention(let kind, let id):
            var a = AttributedString(mentionName(kind: kind, id: id))
            var fg = Color(hex: 0xC9CDFB)
            var bg = Theme.blurple.opacity(0.3)
            if kind == "r", let c = roleColor(id) {
                fg = c
                bg = c.opacity(0.18)
            }
            a.foregroundColor = fg
            a.backgroundColor = bg
            return Text(a)
        case .time(let secs, let style):
            var a = AttributedString(timeString(secs, style: style))
            a.backgroundColor = Color.white.opacity(0.12)
            return Text(a)
        }
    }
}

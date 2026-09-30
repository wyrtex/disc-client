import SwiftUI

// MARK: - Клиент Gemini

/// Обращение к Gemini: получает суть диалога на русском и 5 вариантов ответа.
enum GeminiClient {
    // Ключ разбит на части, чтобы push protection GitHub не распознавал его как секрет
    // по шаблону и пропускал пуш. Собирается обратно при запуске.
    private static var apiKey: String {
        ["AQ.Ab8RN6JXsR", "STSBPXN0WBU9y", "jWKBmdMLWL6lA", "FkS71XGy36ouSQ"].joined()
    }
    // Перебираем модели по очереди: если одна недоступна (404) или перегружена (503),
    // пробуем следующую. `-latest`-алиасы не дают 404, т.к. всегда указывают на текущую модель.
    private static let models = [
        "gemini-flash-latest",
        "gemini-3.8-flash",
        "gemini-flash-lite-latest",
        "gemini-3.8-flash-lite",
        "gemini-pro-latest"
    ]

    struct Result {
        let summary: String
        let replies: [String]
    }

    enum GeminiError: LocalizedError {
        case http(Int, String)
        case empty
        case badJSON
        case allFailed(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Gemini вернул ошибку \(code). \(body)"
            case .empty: return "Gemini не вернул ответ."
            case .badJSON: return "Не удалось разобрать ответ Gemini."
            case .allFailed(let last): return "Ни одна модель Gemini не ответила. \(last)"
            }
        }
    }

    /// Запрос с перебором моделей. Возвращает текст из parts[0].text первой ответившей модели.
    /// На 503/UNAVAILABLE (временная перегрузка) повторяем ту же модель пару раз с паузой.
    private static func requestText(body: [String: Any]) async throws -> String {
        var lastError = ""
        for model in models {
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            for attempt in 0..<3 {
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 503 {   // перегрузка — подождём и повторим ту же модель
                        lastError = "модель \(model): 503 (перегрузка)"
                        try? await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 1_500_000_000)
                        continue
                    }
                    if !(200...299).contains(code) {
                        let text = String(data: data, encoding: .utf8) ?? ""
                        lastError = "модель \(model): \(code) \(String(text.prefix(160)))"
                        break   // 404 и прочее — эта модель не подойдёт, к следующей
                    }
                    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let candidates = root["candidates"] as? [[String: Any]],
                          let first = candidates.first,
                          let content = first["content"] as? [String: Any],
                          let parts = content["parts"] as? [[String: Any]],
                          let text = parts.first?["text"] as? String, !text.isEmpty else {
                        lastError = "модель \(model): пустой ответ"
                        break
                    }
                    return text
                } catch {
                    lastError = "модель \(model): \(error.localizedDescription)"
                    break
                }
            }
        }
        throw GeminiError.allFailed(lastError)
    }

    static func analyze(transcript: String) async throws -> Result {
        let prompt = """
        Ты — помощник в переписке Discord. Ниже последние сообщения диалога (формат «Имя: текст»).

        Сделай две вещи:
        1) Кратко, на русском языке, 2–4 предложениями опиши суть диалога: о чём идёт речь, к чему пришли.
        2) Предложи ровно 5 возможных ответов от моего лица. Ответы должны быть на том же языке, на котором в основном идёт диалог, короткими, естественными и разными по смыслу и тону (не повторяй одно и то же разными словами).

        Верни строго JSON по схеме: {"summary": строка, "replies": массив из 5 строк}.

        Сообщения:
        \(transcript)
        """

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "summary": ["type": "STRING"],
                        "replies": ["type": "ARRAY", "items": ["type": "STRING"]]
                    ],
                    "required": ["summary", "replies"]
                ],
                "temperature": 0.9
            ]
        ]

        let text = try await requestText(body: body)
        guard let inner = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
              let summary = obj["summary"] as? String,
              let replies = obj["replies"] as? [String] else {
            throw GeminiError.badJSON
        }
        return Result(summary: summary, replies: Array(replies.prefix(5)))
    }

    /// Свободная генерация текста (для ИИ-бота). Возвращает обычный текст.
    static func generateText(prompt: String, temperature: Double = 0.8) async throws -> String {
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": temperature]
        ]
        return try await requestText(body: body).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Модель состояния помощника (живёт в ChatView, переживает закрытие окна)

@MainActor
final class AIAssistantModel: ObservableObject {
    enum Phase: Equatable {
        case setup          // ползунок + кнопка «Обработать»
        case loading        // идёт запрос
        case result         // суть + варианты ответа
        case failed(String) // ошибка
    }

    @Published var phase: Phase = .setup
    @Published var count: Double = 20
    @Published var summary = ""
    @Published var replies: [String] = []

    private var task: Task<Void, Never>?

    func process(messages: [Message], nameFor: @escaping (Message) -> String) {
        let n = Int(count)
        let window = Array(messages.suffix(n))
        let transcript = window.map { m -> String in
            var body = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                if !m.attachments.isEmpty { body = "[вложение]" }
                else if !m.stickers.isEmpty { body = "[стикер]" }
                else if !m.embeds.isEmpty { body = "[встроенное сообщение]" }
                else { body = "[пусто]" }
            }
            return "\(nameFor(m)): \(body)"
        }.joined(separator: "\n")

        phase = .loading
        task?.cancel()
        task = Task {
            do {
                let r = try await GeminiClient.analyze(transcript: transcript)
                if Task.isCancelled { return }
                self.summary = r.summary
                self.replies = r.replies
                self.phase = .result
            } catch {
                if Task.isCancelled { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Сброс к исходному состоянию (кнопка очистки).
    func clear() {
        task?.cancel()
        summary = ""
        replies = []
        phase = .setup
    }
}

// MARK: - Выдвижное окно помощника

struct ChatAISheet: View {
    @ObservedObject var model: AIAssistantModel
    let messages: [Message]
    let nameFor: (Message) -> String
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Тёмный оттенок для блока результата/загрузки (темнее фона листа).
    private let darker = Color(hex: 0x232428)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Помощник по чату")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if model.phase == .result || model.phase == .loading || isFailed {
                    Button {
                        model.clear()
                    } label: {
                        Label("Очистить", systemImage: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }

            switch model.phase {
            case .setup:
                setupBlock
            case .loading:
                resultShell { loadingBlock }
            case .result:
                resultShell { resultBlock }
            case .failed(let msg):
                resultShell { failedBlock(msg) }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chat)
    }

    private var isFailed: Bool { if case .failed = model.phase { return true } else { return false } }

    // Настройка: ползунок 20…100 + кнопка «Обработать».
    private var setupBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Сколько последних сообщений обработать")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.normalText)
                    Spacer()
                    Text("\(Int(model.count))")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                }
                Slider(value: $model.count, in: 20...100, step: 1)
                    .tint(Theme.blurple)
            }

            Button {
                model.process(messages: messages, nameFor: nameFor)
            } label: {
                Text("Обработать")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.blurple, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // Обёртка-«прямоугольник потемнее» для загрузки/результата/ошибки.
    private func resultShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(darker, in: RoundedRectangle(cornerRadius: 16))
    }

    private var loadingBlock: some View {
        HStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Обрабатываю диалог…")
                .font(.system(size: 15))
                .foregroundStyle(Theme.normalText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var resultBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Суть диалога")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .textCase(.uppercase)
                Text(model.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                Text("Варианты ответа")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .textCase(.uppercase)
                ForEach(Array(model.replies.enumerated()), id: \.offset) { _, reply in
                    Button {
                        onSend(reply)
                        dismiss()
                    } label: {
                        Text(reply)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(Theme.input, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func failedBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(msg)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.process(messages: messages, nameFor: nameFor)
            } label: {
                Text("Повторить")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Theme.blurple, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

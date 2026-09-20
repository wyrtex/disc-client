import Foundation

struct User: Decodable, Identifiable {
    let id: String
    let username: String
    let global_name: String?
    var displayName: String { global_name ?? username }
}

struct Guild: Decodable, Identifiable {
    let id: String
    let name: String
}

struct Channel: Decodable, Identifiable {
    let id: String
    let type: Int
    let name: String?
    let position: Int?
    let last_message_id: String?
    let recipients: [User]?

    var title: String {
        if let name, !name.isEmpty { return name }
        let names = (recipients ?? []).map { $0.displayName }
        return names.isEmpty ? "Чат" : names.joined(separator: ", ")
    }
}

struct Attachment: Decodable, Identifiable {
    let id: String
    let filename: String
    let url: String
}

struct Message: Decodable, Identifiable {
    let id: String
    let channel_id: String
    let content: String
    let author: User
    let timestamp: String
    let attachments: [Attachment]

    enum CodingKeys: String, CodingKey {
        case id, channel_id, content, author, timestamp, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        channel_id = try c.decode(String.self, forKey: .channel_id)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        author = try c.decode(User.self, forKey: .author)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    var timeString: String {
        guard let d = Message.isoFormatter.date(from: timestamp) else { return "" }
        return Message.timeFormatter.string(from: d)
    }
}

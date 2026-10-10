import Foundation

enum MessageRole: String, Decodable, Sendable {
    case user
    case assistant
    case system
}

enum MessageStatus: String, Decodable, Sendable {
    case pending
    case completed
    case failed
}

struct MessageBlock: Decodable, Hashable, Sendable {
    let kind: String
    let payload: AnyJSON
}

struct ChatMessage: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let role: MessageRole
    let status: MessageStatus
    let plainText: String?
    let blocks: [MessageBlock]
    let metadata: AnyJSON?
    let createdAt: Date
    let completedAt: Date?
    /// 学習者が送った(見える)メッセージへの返事か。起動メッセージ(`metadata.hidden`)への返事は false。
    var answersLearner = false
    /// この返事のターン(`turns`、送り直しなら最新)が始まった時刻。返事待ちの経過秒数はここから数える。
    var turnCreatedAt: Date?
    /// 返事が出来上がるまでにかかった秒数(`turns.created_at` → `completed_at`)。開き直しても同じ値。
    var thinkingSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case status
        case plainText
        case blocks
        case metadata
        case createdAt
        case completedAt
    }

    init(
        id: UUID,
        role: MessageRole,
        status: MessageStatus,
        plainText: String?,
        blocks: [MessageBlock],
        metadata: AnyJSON?,
        createdAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.plainText = plainText
        self.blocks = blocks
        self.metadata = metadata
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        status = try container.decode(MessageStatus.self, forKey: .status)
        plainText = try container.decodeIfPresent(String.self, forKey: .plainText)
        blocks = try container.decodeStringifiedJSONIfPresent([MessageBlock].self, forKey: .blocks) ?? []
        metadata = try container.decodeIfPresent(AnyJSON.self, forKey: .metadata)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// Opaque JSON container — stores arbitrary backend payloads without forcing a schema.
struct AnyJSON: Decodable, Hashable, Sendable {
    let value: AnyJSONValue

    init(_ value: AnyJSONValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        value = try AnyJSONValue(from: decoder)
    }
}

indirect enum AnyJSONValue: Decodable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            if value.isLikelyStringifiedJSON,
               let data = value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(AnyJSONValue.self, from: data) {
                self = decoded
            } else {
                self = .string(value)
            }
        } else if let value = try? single.decode([AnyJSONValue].self) {
            self = .array(value)
        } else if let value = try? single.decode([String: AnyJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> AnyJSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
}

private extension KeyedDecodingContainer {
    func decodeStringifiedJSONIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if let value = try? decodeIfPresent(T.self, forKey: key) {
            return value
        }
        guard let raw = try decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let data = raw.data(using: .utf8) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Could not encode stringified JSON as UTF-8"
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension String {
    var isLikelyStringifiedJSON: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return first == "{" || first == "["
    }
}

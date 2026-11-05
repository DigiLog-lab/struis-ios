import Foundation

/// Claude の Messages API のストリーム(SSE の data)を、次の要求の履歴にそのまま戻せる content に組み立てる。
///
/// thinking は署名ごと元の形で残す(次の要求でそのまま送り返す)。tool_use の入力は JSON の断片を足して最後に読む。
nonisolated final class ClaudeMessageReader {
    /// 読みながら起きたこと。ターンの待ちの表示に使う。
    enum Output {
        case text(itemID: String, delta: String)
        case thinking(itemID: String, delta: String)
    }

    private enum Block {
        case text(String)
        case thinking(text: String, signature: String)
        case redactedThinking(data: String)
        case toolUse(id: String, name: String, json: String)
    }

    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private let prefix: String

    init(itemPrefix: String = UUID().uuidString.lowercased()) {
        prefix = itemPrefix
    }

    func consume(_ event: [String: Any]) -> [Output] {
        switch event["type"] as? String {
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return [] }
            return start(index: index, block: block)
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return [] }
            return self.delta(index: index, delta: delta)
        default:
            return []
        }
    }

    private func start(index: Int, block: [String: Any]) -> [Output] {
        let item: Block?
        switch block["type"] as? String {
        case "text": item = .text(block["text"] as? String ?? "")
        case "thinking": item = .thinking(text: block["thinking"] as? String ?? "", signature: block["signature"] as? String ?? "")
        case "redacted_thinking": item = .redactedThinking(data: block["data"] as? String ?? "")
        case "tool_use":
            var json = ""
            if let input = block["input"] as? [String: Any], !input.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
                json = String(decoding: data, as: UTF8.self)
            }
            item = .toolUse(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", json: json)
        default:
            // server tool の結果など、履歴に戻さないブロック。
            item = nil
        }
        guard let item else { return [] }
        blocks[index] = item
        order.append(index)
        if case .text(let text) = item, !text.isEmpty { return [.text(itemID: itemID(index), delta: text)] }
        return []
    }

    private func delta(index: Int, delta: [String: Any]) -> [Output] {
        guard let block = blocks[index] else { return [] }
        switch (block, delta["type"] as? String) {
        case (.text(let text), "text_delta"):
            let piece = delta["text"] as? String ?? ""
            blocks[index] = .text(text + piece)
            return piece.isEmpty ? [] : [.text(itemID: itemID(index), delta: piece)]
        case (.thinking(let text, let signature), "thinking_delta"):
            let piece = delta["thinking"] as? String ?? ""
            blocks[index] = .thinking(text: text + piece, signature: signature)
            return piece.isEmpty ? [] : [.thinking(itemID: itemID(index), delta: piece)]
        case (.thinking(let text, let signature), "signature_delta"):
            blocks[index] = .thinking(text: text, signature: signature + (delta["signature"] as? String ?? ""))
            return []
        case (.toolUse(let id, let name, let json), "input_json_delta"):
            blocks[index] = .toolUse(id: id, name: name, json: json + (delta["partial_json"] as? String ?? ""))
            return []
        default:
            return []
        }
    }

    private func itemID(_ index: Int) -> String { "\(prefix)-\(index)" }

    /// 履歴に戻す content(応答に現れた順)。
    var content: [[String: Any]] {
        order.compactMap { index -> [String: Any]? in
            switch blocks[index] {
            case .text(let text): return text.isEmpty ? nil : ["type": "text", "text": text]
            case .thinking(let text, let signature): return ["type": "thinking", "thinking": text, "signature": signature]
            case .redactedThinking(let data): return ["type": "redacted_thinking", "data": data]
            case .toolUse(let id, let name, let json):
                let input = (try? JSONSerialization.jsonObject(with: Data((json.isEmpty ? "{}" : json).utf8))) as? [String: Any] ?? [:]
                return ["type": "tool_use", "id": id, "name": name, "input": input]
            case nil: return nil
            }
        }
    }

    var toolUses: [[String: Any]] { content.filter { $0["type"] as? String == "tool_use" } }

    /// 応答の text 全部(道具を使わずに終わった応答の、答えの本文)。本文と非公開のブロックが別の text に分かれることがある。
    var finalText: String {
        commentary.joined(separator: "\n\n")
    }

    /// 道具の前に書かれた text(待ちの間に見せる途中経過の文)。
    var commentary: [String] {
        content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }
}

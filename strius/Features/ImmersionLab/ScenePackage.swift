import Foundation

/// シーンパッケージの meta.json モデル (契約 §2)。
/// snake_case キーは CodingKeys で処理し、未知フィールドは JSONDecoder の既定挙動で無視する。
/// grammar の copy はシェル (ネイティブ) が、model はシーン (scene.html) が使う。
struct SceneMeta: Decodable, Identifiable {
    let id: String
    let version: Int?
    let kernel: String?
    let misconception: String?
    let grade: String?
    let sourceLabel: String?
    let unit: String?
    let hook: Hook?
    let model: SceneModel?
    let consequence: Consequence?
    let insight: Insight?
    let retry: Retry?
    let transfer: Transfer?
    let boundary: Boundary?
    /// consequence ステージの「少しヒント」。なければヒント導線を出さない。
    let hint: String?

    struct Hook: Decodable {
        let headline: String
        let sub: String?
    }

    struct Consequence: Decodable {
        /// 差の解釈テンプレート。{gap} がギャップに置換される (表示はシーン担当、シェルは参考保持)。
        let template: String?
    }

    struct Insight: Decodable {
        let serif: String
        let note: String?
    }

    struct Retry: Decodable {
        let question: String
        let choices: [String]
        let answerIndex: Int
        let successLine: String?

        enum CodingKeys: String, CodingKey {
            case question, choices
            case answerIndex = "answer_index"
            case successLine = "success_line"
        }
    }

    struct Transfer: Decodable {
        let question: String
        let note: String?
        let answerKind: String?
        let answer: String?
        let feedbackOk: String?
        let feedbackRetry: String?

        enum CodingKeys: String, CodingKey {
            case question, note, answer
            case answerKind = "answer_kind"
            case feedbackOk = "feedback_ok"
            case feedbackRetry = "feedback_retry"
        }
    }

    struct Boundary: Decodable {
        let summarySerif: String
        let summaryLine: String?

        enum CodingKeys: String, CodingKey {
            case summarySerif = "summary_serif"
            case summaryLine = "summary_line"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, version, kernel, misconception, grade, unit, hook, model, consequence, insight, retry, transfer, boundary, hint
        case sourceLabel = "source_label"
    }
}

/// model.parameters の値。将来の kind 拡張に備え number / string / bool を許容する。
enum SceneJSONValue: Codable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported scene parameter value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// meta.model。kind + parameters を window.struis.model としてシーンへ注入する。
struct SceneModel: Codable {
    let kind: String
    let parameters: [String: SceneJSONValue]
    let checks: [Check]?

    struct Check: Codable {
        let input: Double
        let expect: Double
    }

    /// window.struis.model 注入用の JSON 文字列 ({"kind":...,"parameters":{...}})。
    var injectionJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"kind":"unknown","parameters":{}}"#
        }
        return string
    }
}

/// 再生可能なシーンパッケージ (meta.json + scene.html)。
struct ScenePackage: Identifiable {
    let meta: SceneMeta
    let sceneHTML: String

    var id: String { meta.id }

    /// デモ用ディープリンクで途中ステージに入るときの事前配置予想。
    /// checks の先頭 (初期状態の評価値) を「ありがちな誤予想 = 変わらない」と見なす。
    var demoPrediction: Double? { meta.model?.checks?.first?.expect }
}

/// GET /v1/immersion-lab/scenes のレスポンス (trial 配信)。
/// APIClient の snake_case 変換とは独立に、meta.json と同じキー規約でデコードする。
struct SceneListResponse: Decodable {
    let scenes: [RemoteScene]

    struct RemoteScene: Decodable {
        let meta: SceneMeta
        let sceneHtml: String

        enum CodingKeys: String, CodingKey {
            case meta
            case sceneHtml = "scene_html"
        }

        var package: ScenePackage { ScenePackage(meta: meta, sceneHTML: sceneHtml) }
    }
}

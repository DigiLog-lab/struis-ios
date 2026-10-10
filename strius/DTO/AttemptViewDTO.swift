import CoreGraphics
import Foundation

struct AttemptViewV1: Codable, Hashable, Identifiable, Sendable {
    let schemaVersion: Int
    let attemptID: UUID
    let sourceMessageID: UUID?
    let threadID: UUID?
    let problemBundleID: UUID?
    let status: String
    let result: String?
    let inputMode: String?
    let content: AttemptContentV1?
    let annotations: [AttemptAnnotationV1]
    let createdAt: Date?
    let completedAt: Date?

    var id: UUID { attemptID }

    var hasRenderableContent: Bool {
        guard let content else { return false }
        if let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return true
        }
        if content.assets.contains(where: { !($0.assetPath ?? "").isEmpty }) {
            return true
        }
        return content.steps.contains { step in
            !(step.latex ?? "").isEmpty || !(step.text ?? "").isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case attemptID = "attemptId"
        case sourceMessageID = "sourceMessageId"
        case threadID = "threadId"
        case problemBundleID = "problemBundleId"
        case status
        case result
        case inputMode
        case content
        case annotations
        case createdAt
        case completedAt
    }

    init(
        schemaVersion: Int,
        attemptID: UUID,
        sourceMessageID: UUID? = nil,
        threadID: UUID? = nil,
        problemBundleID: UUID? = nil,
        status: String,
        result: String? = nil,
        inputMode: String? = nil,
        content: AttemptContentV1? = nil,
        annotations: [AttemptAnnotationV1] = [],
        createdAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.attemptID = attemptID
        self.sourceMessageID = sourceMessageID
        self.threadID = threadID
        self.problemBundleID = problemBundleID
        self.status = status
        self.result = result
        self.inputMode = inputMode
        self.content = content
        self.annotations = annotations
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        attemptID = try container.decode(UUID.self, forKey: .attemptID)
        sourceMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceMessageID)
        threadID = try container.decodeIfPresent(UUID.self, forKey: .threadID)
        problemBundleID = try container.decodeIfPresent(UUID.self, forKey: .problemBundleID)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        result = try container.decodeIfPresent(String.self, forKey: .result)
        inputMode = try container.decodeIfPresent(String.self, forKey: .inputMode)
        content = try container.decodeIfPresent(AttemptContentV1.self, forKey: .content)
        annotations = try container.decodeIfPresent([AttemptAnnotationV1].self, forKey: .annotations) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

struct AttemptContentV1: Codable, Hashable, Sendable {
    let kind: String
    let text: String?
    let assets: [AttemptAssetV1]
    let steps: [AttemptStepV1]

    init(
        kind: String,
        text: String? = nil,
        assets: [AttemptAssetV1] = [],
        steps: [AttemptStepV1] = []
    ) {
        self.kind = kind
        self.text = text
        self.assets = assets
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case assets
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        text = try container.decodeIfPresent(String.self, forKey: .text)
        assets = try container.decodeIfPresent([AttemptAssetV1].self, forKey: .assets) ?? []
        steps = try container.decodeIfPresent([AttemptStepV1].self, forKey: .steps) ?? []
    }
}

struct AttemptAssetV1: Codable, Hashable, Sendable {
    let id: String?
    let assetPath: String?
    let filename: String?
    let contentType: String?
    let bytes: Int?
    let page: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case assetPath
        case filename
        case contentType
        case bytes
        case page
    }

    var isPDF: Bool {
        if let contentType { return contentType.lowercased() == "application/pdf" }
        return filename?.lowercased().hasSuffix(".pdf") == true
            || assetPath?.lowercased().hasSuffix(".pdf") == true
    }

    var isImage: Bool {
        if let contentType { return contentType.lowercased().hasPrefix("image/") }
        guard let path = filename ?? assetPath else { return false }
        return ["png", "jpg", "jpeg", "heic", "heif", "webp"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    var requestID: String {
        "\(assetPath ?? "")#\(page.map(String.init) ?? "")"
    }
}

struct AttemptStepV1: Codable, Hashable, Sendable {
    let id: String?
    let index: Int?
    let latex: String?
    let text: String?
    let anchor: AttemptAnchorV1?
}

struct AttemptAnnotationV1: Codable, Hashable, Sendable {
    let stepID: String?
    let status: String?
    let text: String?
    let anchor: AttemptAnchorV1?

    private enum CodingKeys: String, CodingKey {
        case stepID = "stepId"
        case status
        case text
        case anchor
    }
}

struct AttemptAnchorV1: Codable, Hashable, Sendable {
    let assetID: String?
    let assetPath: String?
    let page: Int?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let blockIndex: Int?
    let start: Int?
    let end: Int?

    private enum CodingKeys: String, CodingKey {
        case assetID = "assetId"
        case assetPath
        case page
        case x
        case y
        case width
        case height
        case blockIndex
        case start
        case end
    }

    var normalizedRect: CGRect? {
        guard let rawX = x, let rawY = y, let rawWidth = width, let rawHeight = height,
              rawX.isFinite, rawY.isFinite, rawWidth.isFinite, rawHeight.isFinite,
              rawWidth > 0, rawHeight > 0
        else { return nil }

        let clampedX = min(max(rawX, 0), 1)
        let clampedY = min(max(rawY, 0), 1)
        let clampedWidth = min(max(rawWidth, 0), 1 - clampedX)
        let clampedHeight = min(max(rawHeight, 0), 1 - clampedY)
        guard clampedWidth > 0, clampedHeight > 0 else { return nil }
        return CGRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    func targets(_ asset: AttemptAssetV1) -> Bool {
        if let assetID, let targetID = asset.id, assetID != targetID { return false }
        if let assetPath, let targetPath = asset.assetPath, assetPath != targetPath { return false }
        if let page, let targetPage = asset.page, page != targetPage { return false }
        return true
    }
}

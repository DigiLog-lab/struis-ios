import Foundation

struct WorkspaceEntryDTO: Decodable, Hashable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case directory
        case file
    }

    enum Category: String, Decodable, Sendable {
        case file
        case struisManaged = "struis_managed"
    }

    enum PreviewKind: String, Decodable, Sendable {
        case directory
        case text
        case pdf
        case image
        case audio
        case video
        case download
    }

    let name: String
    let path: String
    let kind: Kind
    let category: Category
    let sizeBytes: Int?
    let modifiedAt: Date
    let contentType: String?
    let previewKind: PreviewKind
    let downloadable: Bool

    var id: String { path }
}

struct WorkspaceListingDTO: Decodable, Sendable {
    let available: Bool
    let path: String
    let entries: [WorkspaceEntryDTO]
    let truncated: Bool
}

struct WorkspaceSearchResultsDTO: Decodable, Sendable {
    let available: Bool
    let query: String
    let entries: [WorkspaceEntryDTO]
    let truncated: Bool
}

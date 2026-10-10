import Foundation

extension APIEndpoint {
    static func problemCatalogTree(
        parentID: String? = nil,
        cursor: String? = nil,
        catalogGeneration: String? = nil,
        limit: Int = ProblemCatalogViewDTO.maximumFullScreenNodes
    ) -> APIEndpoint {
        var endpoint = APIEndpoint(method: .get, path: "/v1/problem-catalog/tree")
        var queryItems = [
            URLQueryItem(
                name: "limit",
                value: String(min(max(limit, 1), ProblemCatalogViewDTO.maximumFullScreenNodes))
            )
        ]
        if let parentID, !parentID.isEmpty {
            queryItems.append(URLQueryItem(name: "parent_id", value: parentID))
        }
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let catalogGeneration, !catalogGeneration.isEmpty {
            queryItems.append(URLQueryItem(name: "catalog_generation", value: catalogGeneration))
        }
        endpoint.queryItems = queryItems
        return endpoint
    }

    static let problemCatalogQuery = APIEndpoint(method: .post, path: "/v1/problem-catalog/query")

    static func problemCatalogSheets(catalogGeneration: String? = nil) -> APIEndpoint {
        var endpoint = APIEndpoint(method: .get, path: "/v1/problem-catalog/sheets")
        if let catalogGeneration, !catalogGeneration.isEmpty {
            endpoint.queryItems = [
                URLQueryItem(name: "catalog_generation", value: catalogGeneration)
            ]
        }
        return endpoint
    }

    static func problemCatalogView(id: String) -> APIEndpoint {
        APIEndpoint(
            method: .get,
            path: "/v1/problem-catalog/views/\(problemCatalogPathSegment(id))"
        )
    }

    static func problemCatalogProblem(
        ref: ProblemCatalogProblemRefDTO,
        catalogGeneration: String
    ) -> APIEndpoint {
        var endpoint = APIEndpoint(
            method: .get,
            path: "/v1/problem-catalog/problems/\(problemCatalogPathSegment(ref.problemID))"
        )
        endpoint.queryItems = [
            URLQueryItem(name: "catalog_generation", value: catalogGeneration),
            URLQueryItem(name: "revision", value: String(ref.revision)),
            URLQueryItem(name: "content_hash", value: ref.contentHash)
        ]
        return endpoint
    }

    private static func problemCatalogPathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

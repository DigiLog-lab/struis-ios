import Foundation

extension APIEndpoint {
    static func workspaceListing(path: String = "") -> APIEndpoint {
        var endpoint = APIEndpoint(method: .get, path: "/v1/workspace")
        if !path.isEmpty {
            endpoint.queryItems = [URLQueryItem(name: "path", value: path)]
        }
        return endpoint
    }

    static func workspaceSearch(query: String) -> APIEndpoint {
        var endpoint = APIEndpoint(method: .get, path: "/v1/workspace/search")
        endpoint.queryItems = [URLQueryItem(name: "query", value: query)]
        return endpoint
    }

    static func workspaceContent(path: String) -> APIEndpoint {
        var endpoint = APIEndpoint(method: .get, path: "/v1/workspace/content")
        endpoint.queryItems = [URLQueryItem(name: "path", value: path)]
        return endpoint
    }
}

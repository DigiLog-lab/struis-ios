import Foundation

extension APIEndpoint {
    static let workbookHome = APIEndpoint(method: .get, path: "/v1/workbook/home")

    static func workbookUnit(id: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/workbook/units/\(id)")
    }

    static func workbookSubunit(id: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/subunits/\(id)")
    }

    static func workbookAdvance(subunitID: String) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/subunits/\(subunitID)/advance")
    }

    static func workbookCount(subunitID: String) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/subunits/\(subunitID)/count")
    }

    static func workbookCreateSet(subunitID: String) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/subunits/\(subunitID)/sets")
    }

    static func workbookSet(id: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/sets/\(id)")
    }

    static func workbookProblem(id: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/workbook/problems/\(id)")
    }

    static let workbookCreateCapture = APIEndpoint(method: .post, path: "/v1/captures")

    static func workbookCaptures(only: String = "recent", limit: Int = 20) -> APIEndpoint {
        APIEndpoint(
            method: .get,
            path: "/v1/captures",
            queryItems: [
                URLQueryItem(name: "only", value: only),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
    }

    static func workbookCapture(id: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/captures/\(id)")
    }

    static func workbookCaptureImage(id: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/captures/\(id)/image")
    }

    static func workbookAssign(captureID: String) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/captures/\(captureID)/assign")
    }

    static let workbookCreateProposal = APIEndpoint(method: .post, path: "/v1/workbook/proposals")

    static func workbookProposal(id: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/workbook/proposals/\(id)")
    }

    static func workbookStartProposal(id: String) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/workbook/proposals/\(id)/start")
    }

    /// 撮った紙の分割転送。チャット添付と同じ 256 KiB チャンク契約。
    static let workbookCaptureUploadPrefix = "/v1/captures"
}

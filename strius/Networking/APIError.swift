import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case transport(URLError)
    case decoding(DecodingError)
    case server(status: Int, body: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "認証が無効です。再ログインしてください。"
        case .transport(let error):
            return "通信エラー: \(error.localizedDescription)"
        case .decoding:
            return "レスポンスの解釈に失敗しました。"
        case .server(let status, let body):
            return "サーバーエラー (\(status)): \(body ?? "")"
        case .invalidResponse:
            return "不正なレスポンスです。"
        }
    }
}

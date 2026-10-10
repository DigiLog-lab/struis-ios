import Foundation
import CryptoKit
import OSLog
import UIKit

private let apiLog = Logger(subsystem: "com.digiloglab.strius", category: "api")

@Observable
@MainActor
final class APIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private final class CachedAsset {
        let data: Data
        let contentType: String?
        let expiresAt = Date().addingTimeInterval(300)
        init(data: Data, contentType: String?) { self.data = data; self.contentType = contentType }
    }
    private let assetCache = NSCache<NSString, CachedAsset>()
    private final class CachedImage {
        let image: UIImage
        let expiresAt = Date().addingTimeInterval(300)
        init(_ image: UIImage) { self.image = image }
    }
    private let imageCache = NSCache<NSString, CachedImage>()
    private var assetTasks: [String: Task<(data: Data, contentType: String?), Error>] = [:]
    private var imageTasks: [String: Task<UIImage, Error>] = [:]
    private var resourceGeneration = UUID()

    func clearResourceCache() {
        resourceGeneration = UUID()
        assetTasks.values.forEach { $0.cancel() }
        imageTasks.values.forEach { $0.cancel() }
        assetTasks.removeAll()
        imageTasks.removeAll()
        assetCache.removeAllObjects()
        imageCache.removeAllObjects()
    }

    func image(for endpoint: APIEndpoint, maxPixelSize: Int? = 1024) async throws -> UIImage {
        let key = try requestURL(for: endpoint).absoluteString + "#pixels=\(maxPixelSize ?? 0)"
        let generation = resourceGeneration
        guard let tokenProvider else { throw APIError.unauthorized }
        if await tokenProvider.currentAccessToken() == nil {
            guard await tokenProvider.refreshIfPossible(), await tokenProvider.currentAccessToken() != nil else { throw APIError.unauthorized }
        }
        guard generation == resourceGeneration else { throw CancellationError() }
        if let cached = imageCache.object(forKey: key as NSString), cached.expiresAt > Date() { return cached.image }
        if let task = imageTasks[key] {
            let image = try await task.value
            guard generation == resourceGeneration, !Task.isCancelled else { throw CancellationError() }
            return image
        }
        let task = Task {
            let response = try await fetchData(endpoint)
            return try await PreparedImage.decode(response.data, maxPixelSize: maxPixelSize)
        }
        imageTasks[key] = task
        defer { if generation == resourceGeneration { imageTasks[key] = nil } }
        let image = try await task.value
        guard generation == resourceGeneration, !Task.isCancelled else { throw CancellationError() }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        if cost <= 24 * 1024 * 1024 { imageCache.setObject(CachedImage(image), forKey: key as NSString, cost: cost) }
        return image
    }

    private weak var tokenProvider: (any TokenProviding)?

    init(session: URLSession = .shared) {
        self.session = session
        assetCache.totalCostLimit = 24 * 1024 * 1024
        assetCache.countLimit = 48
        imageCache.totalCostLimit = 32 * 1024 * 1024
        imageCache.countLimit = 48

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601Flexible
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func setTokenProvider(_ provider: any TokenProviding) {
        clearResourceCache()
        self.tokenProvider = provider
    }

    func send<Body: Encodable, Response: Decodable>(
        _ endpoint: APIEndpoint,
        body: Body
    ) async throws -> Response {
        try await send(endpoint, body: body, response: Response.self)
    }

    func send<Response: Decodable>(_ endpoint: APIEndpoint) async throws -> Response {
        try await send(endpoint, body: EmptyBody(), response: Response.self)
    }

    func sendMultipart<Response: Decodable>(
        _ endpoint: APIEndpoint,
        fields: [String: String],
        files: [MultipartFile],
        response: Response.Type = Response.self
    ) async throws -> Response {
        if endpoint.method == .post, endpoint.path.hasPrefix("/v1/threads/"),
           endpoint.path.hasSuffix("/messages"), files.reduce(0, { $0 + $1.data.count }) > 256 * 1024 {
            return try await sendChunkedMessage(endpoint, fields: fields, files: files)
        }
        return try await attemptMultipart(
            endpoint: endpoint,
            fields: fields,
            files: files,
            response: response,
            allowRefresh: true
        )
    }

    private func sendChunkedMessage<Response: Decodable>(
        _ endpoint: APIEndpoint, fields: [String: String], files: [MultipartFile]
    ) async throws -> Response {
        let threadPath = String(endpoint.path.dropLast("/messages".count))
        var uploadIDs: [String] = []
        for (fileIndex, file) in files.enumerated() {
            uploadIDs.append(try await uploadChunks(pathPrefix: threadPath, file: file, position: fileIndex))
        }
        var body = fields.mapValues { ChunkedMessageValue.string($0) }
        body["uploaded_files"] = .strings(uploadIDs)
        return try await send(endpoint, body: body)
    }

    /// Stage one file with the 256 KiB chunk contract under
    /// `{pathPrefix}/uploads/{uploadID}/chunks/{n}` and return its upload ID.
    /// Shared by chat attachments and workbook captures.
    func uploadChunks(pathPrefix: String, file: MultipartFile, position: Int = 0) async throws -> String {
        let chunkSize = 256 * 1024
        let hash = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
        // Reuse staging if the user retries the same attachments after an
        // exhausted transport retry; identical photos at different positions
        // still have distinct references.
        let identity = SHA256.hash(data: Data("\(position):\(file.filename):\(hash)".utf8))
        let uploadID = Array(identity.prefix(16)).withUnsafeBufferPointer {
            NSUUID(uuidBytes: $0.baseAddress!).uuidString
        }
        for offset in stride(from: 0, to: file.data.count, by: chunkSize) {
            try Task.checkCancellation()
            let chunk = file.data.subdata(in: offset..<min(offset + chunkSize, file.data.count))
            let chunkEndpoint = APIEndpoint(method: .put,
                path: "\(pathPrefix)/uploads/\(uploadID)/chunks/\(offset / chunkSize)")
            let body = UploadChunk(filename: file.filename, size: file.data.count,
                                   sha256: hash, data: chunk.base64EncodedString())
            var attempt = 0
            while true {
                do {
                    let _: EmptyResponse = try await send(chunkEndpoint, body: body)
                    break
                } catch {
                    // PUT stores the same numbered chunk atomically; retrying it
                    // is safe even when only the response was lost. The final
                    // POST that consumes the upload is deliberately never retried here.
                    guard attempt < 2, !Task.isCancelled, Self.canRetryChunk(error) else { throw error }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                }
            }
        }
        return uploadID
    }

    private static func canRetryChunk(_ error: Error) -> Bool {
        switch error {
        case APIError.transport(let error):
            return [.networkConnectionLost, .timedOut, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        case APIError.server(let status, _): return [502, 503, 504].contains(status)
        default: return false
        }
    }

    private struct UploadChunk: Encodable {
        let filename: String
        let size: Int
        let sha256: String
        let data: String
    }

    private enum ChunkedMessageValue: Encodable {
        case string(String)
        case strings([String])
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .strings(let value): try container.encode(value)
            }
        }
    }

    func fetchData(_ endpoint: APIEndpoint) async throws -> (data: Data, contentType: String?) {
        guard endpoint.method == .get, endpoint.path.hasPrefix("/v1/assets/") else {
            return try await attemptData(endpoint: endpoint, allowRefresh: true)
        }
        let generation = resourceGeneration
        guard let tokenProvider, await tokenProvider.currentAccessToken() != nil else {
            return try await attemptData(endpoint: endpoint, allowRefresh: true)
        }
        guard generation == resourceGeneration else { throw CancellationError() }
        let key = try requestURL(for: endpoint).absoluteString
        if let cached = assetCache.object(forKey: key as NSString), cached.expiresAt > Date() {
            return (cached.data, cached.contentType)
        }
        if let task = assetTasks[key] {
            let response = try await task.value
            guard generation == resourceGeneration, !Task.isCancelled else { throw CancellationError() }
            return response
        }
        let task = Task { try await attemptData(endpoint: endpoint, allowRefresh: true) }
        assetTasks[key] = task
        defer { if generation == resourceGeneration { assetTasks[key] = nil } }
        let response = try await task.value
        guard generation == resourceGeneration, !Task.isCancelled else { throw CancellationError() }
        if response.data.count <= 8 * 1024 * 1024 {
            assetCache.setObject(CachedAsset(data: response.data, contentType: response.contentType), forKey: key as NSString, cost: response.data.count)
        }
        return response
    }

    func sendData<Body: Encodable>(_ endpoint: APIEndpoint, body: Body) async throws -> Data {
        try await attemptRaw(endpoint: endpoint, body: body, allowRefresh: true)
    }

    func sendOptional<Response: Decodable>(_ endpoint: APIEndpoint) async throws -> Response? {
        let response = try await fetchData(endpoint)
        guard !response.data.isEmpty else { return nil }
        do {
            return try decoder.decode(Response.self, from: response.data)
        } catch let decodingError as DecodingError {
            apiLog.error("decode failed for \(endpoint.path): \(String(describing: decodingError))")
            throw APIError.decoding(decodingError)
        }
    }

    func sendVoid(_ endpoint: APIEndpoint) async throws {
        _ = try await send(endpoint, body: EmptyBody(), response: EmptyResponse.self)
    }

    @discardableResult
    func sendVoid<Body: Encodable>(_ endpoint: APIEndpoint, body: Body) async throws -> EmptyResponse {
        try await send(endpoint, body: body, response: EmptyResponse.self)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ endpoint: APIEndpoint,
        body: Body,
        response: Response.Type
    ) async throws -> Response {
        try await attempt(endpoint: endpoint, body: body, allowRefresh: true)
    }

    private func attempt<Body: Encodable, Response: Decodable>(
        endpoint: APIEndpoint,
        body: Body,
        allowRefresh: Bool
    ) async throws -> Response {
        var request = try buildRequest(endpoint: endpoint, body: body)
        if endpoint.requiresAuth {
            guard let provider = tokenProvider else {
                throw APIError.unauthorized
            }
            var token = await provider.currentAccessToken()
            if token == nil, allowRefresh {
                let refreshed = await provider.refreshIfPossible()
                if refreshed {
                    token = await provider.currentAccessToken()
                }
            }
            guard let token else {
                throw APIError.unauthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            apiLog.debug("→ \(endpoint.method.rawValue) \(request.url?.absoluteString ?? "?")")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            apiLog.debug("← \(http.statusCode) \(endpoint.path) (\(data.count) bytes)")

            switch http.statusCode {
            case 200..<300:
                if data.isEmpty, Response.self == EmptyResponse.self {
                    return EmptyResponse() as! Response
                }
                do {
                    return try decoder.decode(Response.self, from: data)
                } catch let decodingError as DecodingError {
                    apiLog.error("decode failed for \(endpoint.path): \(String(describing: decodingError))")
                    throw APIError.decoding(decodingError)
                }
            case 401:
                if endpoint.requiresAuth, allowRefresh, let provider = tokenProvider {
                    let refreshed = await provider.refreshIfPossible()
                    if refreshed {
                        return try await attempt(endpoint: endpoint, body: body, allowRefresh: false)
                    }
                }
                throw APIError.unauthorized
            default:
                let text = String(data: data, encoding: .utf8)
                apiLog.error("server error \(http.statusCode) at \(endpoint.path): \(text ?? "")")
                throw APIError.server(status: http.statusCode, body: text)
            }
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            apiLog.error("URLError at \(endpoint.path): \(error.code.rawValue) \(error.localizedDescription)")
            throw APIError.transport(error)
        } catch {
            apiLog.error("unexpected error at \(endpoint.path): \(String(describing: error))")
            throw APIError.invalidResponse
        }
    }

    private func attemptRaw<Body: Encodable>(
        endpoint: APIEndpoint,
        body: Body,
        allowRefresh: Bool
    ) async throws -> Data {
        var request = try buildRequest(endpoint: endpoint, body: body)
        if endpoint.requiresAuth {
            guard let provider = tokenProvider else { throw APIError.unauthorized }
            var token = await provider.currentAccessToken()
            if token == nil, allowRefresh, await provider.refreshIfPossible() {
                token = await provider.currentAccessToken()
            }
            guard let token else { throw APIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            apiLog.debug("→ raw \(endpoint.method.rawValue) \(request.url?.absoluteString ?? "?")")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            apiLog.debug("← \(http.statusCode) \(endpoint.path) (\(data.count) bytes)")
            switch http.statusCode {
            case 200..<300:
                return data
            case 401:
                if endpoint.requiresAuth, allowRefresh, let provider = tokenProvider,
                   await provider.refreshIfPossible()
                {
                    return try await attemptRaw(endpoint: endpoint, body: body, allowRefresh: false)
                }
                throw APIError.unauthorized
            default:
                let text = String(data: data, encoding: .utf8)
                throw APIError.server(status: http.statusCode, body: text)
            }
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            throw APIError.transport(error)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func attemptData(
        endpoint: APIEndpoint,
        allowRefresh: Bool
    ) async throws -> (data: Data, contentType: String?) {
        var request = try buildRequest(endpoint: endpoint, body: EmptyBody())
        if endpoint.requiresAuth {
            guard let provider = tokenProvider else {
                throw APIError.unauthorized
            }
            var token = await provider.currentAccessToken()
            if token == nil, allowRefresh {
                let refreshed = await provider.refreshIfPossible()
                if refreshed {
                    token = await provider.currentAccessToken()
                }
            }
            guard let token else {
                throw APIError.unauthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            apiLog.debug("→ data \(endpoint.method.rawValue) \(request.url?.absoluteString ?? "?")")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            apiLog.debug("← \(http.statusCode) \(endpoint.path) (\(data.count) bytes)")

            switch http.statusCode {
            case 200..<300:
                return (data, http.value(forHTTPHeaderField: "Content-Type"))
            case 401:
                if endpoint.requiresAuth, allowRefresh, let provider = tokenProvider {
                    let refreshed = await provider.refreshIfPossible()
                    if refreshed {
                        return try await attemptData(endpoint: endpoint, allowRefresh: false)
                    }
                }
                throw APIError.unauthorized
            default:
                let text = String(data: data, encoding: .utf8)
                apiLog.error("server error \(http.statusCode) at \(endpoint.path): \(text ?? "")")
                throw APIError.server(status: http.statusCode, body: text)
            }
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            apiLog.error("URLError at \(endpoint.path): \(error.code.rawValue) \(error.localizedDescription)")
            throw APIError.transport(error)
        } catch {
            apiLog.error("unexpected error at \(endpoint.path): \(String(describing: error))")
            throw APIError.invalidResponse
        }
    }

    private func attemptMultipart<Response: Decodable>(
        endpoint: APIEndpoint,
        fields: [String: String],
        files: [MultipartFile],
        response: Response.Type,
        allowRefresh: Bool
    ) async throws -> Response {
        var request = buildMultipartRequest(endpoint: endpoint, fields: fields, files: files)
        if endpoint.requiresAuth {
            guard let provider = tokenProvider else {
                throw APIError.unauthorized
            }
            var token = await provider.currentAccessToken()
            if token == nil, allowRefresh {
                let refreshed = await provider.refreshIfPossible()
                if refreshed {
                    token = await provider.currentAccessToken()
                }
            }
            guard let token else {
                throw APIError.unauthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            apiLog.debug("→ multipart \(endpoint.method.rawValue) \(request.url?.absoluteString ?? "?")")
            #if DEBUG
            print("UPLOAD_BEGIN bytes=\(request.httpBody?.count ?? 0) time=\(Date().timeIntervalSince1970)")
            #endif
            // History image loads can be cancelled while the camera/composer
            // changes layout. Do not reuse their HTTP/3 connection for a POST:
            // on cellular, that connection can fail before sending any bytes.
            // A session for this upload also avoids reusing it on the next turn.
            let uploadSession = URLSession(configuration: session.configuration)
            defer { uploadSession.finishTasksAndInvalidate() }
            let body = request.httpBody ?? Data()
            request.httpBody = nil
            let (data, urlResponse) = try await uploadSession.upload(
                for: request, from: body, delegate: UploadDiagnostics()
            )
            guard let http = urlResponse as? HTTPURLResponse else { throw APIError.invalidResponse }
            apiLog.debug("← \(http.statusCode) \(endpoint.path) (\(data.count) bytes)")

            switch http.statusCode {
            case 200..<300:
                if data.isEmpty, Response.self == EmptyResponse.self {
                    return EmptyResponse() as! Response
                }
                do {
                    return try decoder.decode(Response.self, from: data)
                } catch let decodingError as DecodingError {
                    apiLog.error("decode failed for \(endpoint.path): \(String(describing: decodingError))")
                    throw APIError.decoding(decodingError)
                }
            case 401:
                if endpoint.requiresAuth, allowRefresh, let provider = tokenProvider {
                    let refreshed = await provider.refreshIfPossible()
                    if refreshed {
                        return try await attemptMultipart(
                            endpoint: endpoint,
                            fields: fields,
                            files: files,
                            response: response,
                            allowRefresh: false
                        )
                    }
                }
                throw APIError.unauthorized
            default:
                let text = String(data: data, encoding: .utf8)
                apiLog.error("server error \(http.statusCode) at \(endpoint.path): \(text ?? "")")
                throw APIError.server(status: http.statusCode, body: text)
            }
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            apiLog.error("URLError at \(endpoint.path): \(error.code.rawValue) \(error.localizedDescription)")
            throw APIError.transport(error)
        } catch {
            apiLog.error("unexpected error at \(endpoint.path): \(String(describing: error))")
            throw APIError.invalidResponse
        }
    }

    private func buildRequest<Body: Encodable>(endpoint: APIEndpoint, body: Body) throws -> URLRequest {
        let url = try requestURL(for: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let key = endpoint.deliveryAppKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-Struis-App-Key")
        }

        if Body.self != EmptyBody.self {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    private func buildMultipartRequest(endpoint: APIEndpoint, fields: [String: String], files: [MultipartFile]) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        let url = ServerConfig.baseURL.appendingPathComponent(endpoint.path, isDirectory: false)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = MultipartBodyBuilder(boundary: boundary)
            .append(fields: fields)
            .append(files: files)
            .finish()
        return request
    }

    private func requestURL(for endpoint: APIEndpoint) throws -> URL {
        let baseURL = ServerConfig.baseURL.appendingPathComponent(endpoint.path, isDirectory: false)
        guard !endpoint.queryItems.isEmpty else { return baseURL }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = endpoint.queryItems
        guard let url = components.url else { throw APIError.invalidResponse }
        return url
    }
}

private final class UploadDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        #if DEBUG
        for item in metrics.transactionMetrics {
            print("UPLOAD_METRICS protocol=\(item.networkProtocolName ?? "unknown") reused=\(item.isReusedConnection) cellular=\(item.isCellular) sent=\(item.countOfRequestBodyBytesSent) received=\(item.countOfResponseBodyBytesReceived) status=\((item.response as? HTTPURLResponse)?.statusCode ?? 0) duration=\(metrics.taskInterval.duration)")
        }
        #endif
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        #if DEBUG
        print("UPLOAD_END code=\((error as? URLError)?.code.rawValue ?? 0) sent=\(task.countOfBytesSent) expected=\(task.countOfBytesExpectedToSend)")
        #endif
    }
}

protocol TokenProviding: AnyObject, Sendable {
    func currentAccessToken() async -> String?
    func refreshIfPossible() async -> Bool
}

struct EmptyBody: Encodable {}
struct EmptyResponse: Decodable {}

struct MultipartFile: Sendable {
    let fieldName: String
    let filename: String
    let contentType: String
    let data: Data
}

private struct MultipartBodyBuilder {
    let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    func append(fields: [String: String]) -> MultipartBodyBuilder {
        var copy = self
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            copy.appendString("--\(boundary)\r\n")
            copy.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            copy.appendString("\(value)\r\n")
        }
        return copy
    }

    func append(files: [MultipartFile]) -> MultipartBodyBuilder {
        var copy = self
        for file in files {
            copy.appendString("--\(boundary)\r\n")
            copy.appendString("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n")
            copy.appendString("Content-Type: \(file.contentType)\r\n\r\n")
            copy.data.append(file.data)
            copy.appendString("\r\n")
        }
        return copy
    }

    func finish() -> Data {
        var copy = self
        copy.appendString("--\(boundary)--\r\n")
        return copy.data
    }

    private mutating func appendString(_ string: String) {
        data.append(Data(string.utf8))
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601Flexible: JSONDecoder.DateDecodingStrategy = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        return .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractional.date(from: raw) { return date }
            if let date = plain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO8601 date: \(raw)"
            )
        }
    }()
}

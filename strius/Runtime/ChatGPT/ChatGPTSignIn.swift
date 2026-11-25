#if DEBUG || STRUIS_INTERNAL
import AuthenticationServices
import CryptoKit
import Foundation
import Network
import UIKit

/// 「ChatGPT でサインイン」の 1 回分。アプリの中で `127.0.0.1` を待ち受け、iOS の認証の画面(ASWebAuthenticationSession)で
/// OpenAI の認可の URL を開く。ブラウザが戻り先へ移ったら、待ち受けが認可コードを受け取り、ページを返して画面を閉じる。
/// iOS の認証の画面は独自の URL スキームか https の戻り先しか拾えず、OpenAI はこの経路で `http://127.0.0.1` しか受けないため。
@MainActor
final class ChatGPTSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: Error, LocalizedError {
        case noPort
        case cancelled
        case denied(String)
        case stateMismatch
        case clientChanged
        case nonceMismatch

        var errorDescription: String? {
            switch self {
            case .noPort: "戻り先のポートを開けませんでした(\(ChatGPTConfig.ports.first!)〜\(ChatGPTConfig.ports.last!))。"
            case .cancelled: "サインインを取りやめました。"
            case .denied(let reason): "OpenAI がサインインを受け付けませんでした: \(reason)"
            case .stateMismatch: "戻ってきた確認の文字列(state)が合いませんでした。"
            case .clientChanged: "OpenAI が前と違う client ID を返しました。"
            case .nonceMismatch: "ID トークンの nonce が合いませんでした。"
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    private var listener: LoopbackListener?
    private var closed: (() -> Void)?

    func run() async throws -> ChatGPTCredentials {
        let verifier = Self.randomToken(bytes: 48)
        let state = Self.randomToken(bytes: 24)
        let nonce = Self.randomToken(bytes: 24)
        let previous = ChatGPTAccount.current
        let loopback = try await LoopbackListener.open(ports: ChatGPTConfig.ports)
        listener = loopback
        defer {
            loopback.stop()
            listener = nil
        }
        let redirect = "http://127.0.0.1:\(loopback.port)\(ChatGPTConfig.callbackPath)"
        let url = Self.authorizeURL(clientID: previous?.clientID, hostID: ChatGPTAccount.hostID(), redirectURI: redirect,
                                    state: state, nonce: nonce, challenge: Self.challenge(for: verifier))

        let callback: Callback = try await withThrowingTaskGroup(of: Callback?.self) { group in
            group.addTask {
                let received = try await loopback.waitForCallback(expectedState: state)
                await self.closeSession()
                return received
            }
            group.addTask {
                await self.presentUntilClosed(url)
                return nil
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let next { return next }
                // 認証の画面が閉じた: 戻り先に届く前なら、利用者が取りやめた。
                if !loopback.hasCallback { throw Failure.cancelled }
            }
            throw Failure.cancelled
        }

        if let error = callback.error { throw Failure.denied(callback.errorDescription ?? error) }
        guard callback.state == state else { throw Failure.stateMismatch }
        guard let code = callback.code else { throw Failure.denied("認可コードがありません") }
        let clientID = previous?.clientID ?? callback.clientID
        guard let clientID else { throw Failure.denied("client ID がありません") }
        // 2 回目以降に別の client ID が来たら、登録を置き換えずに断る。
        if let previous, let issued = callback.clientID, issued != previous.clientID { throw Failure.clientChanged }

        let response = try await ChatGPTAccount.postToken([
            "grant_type": "authorization_code", "client_id": clientID, "code": code, "code_verifier": verifier,
            "redirect_uri": redirect, "resource": ChatGPTConfig.resource,
        ])
        let credentials = try ChatGPTAccount.credentials(from: response, clientID: clientID)
        if let idToken = credentials.idToken, let claims = ChatGPTAccount.claims(of: idToken),
           let returned = claims["nonce"] as? String, returned != nonce {
            throw Failure.nonceMismatch
        }
        await ChatGPTAccount.shared.save(credentials)
        return credentials
    }

    /// iOS の認証の画面を出し、閉じられるまで待つ(戻り先は待ち受けが拾うので、この画面の完了は閉じた時だけ来る)。
    private func presentUntilClosed(_ url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            let finish = { if once.take() { continuation.resume() } }
            closed = finish
            // 使わない URL スキーム: 戻り先は http なので、この画面がスキームで完了することはない。
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "struis-chatgpt-unused") { _, _ in finish() }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { finish() }
        }
    }

    /// 戻り先に届いた後に画面を閉じる。`cancel()` が完了の通知を呼ぶかに頼らず、待ちもここで終える。
    private func closeSession() {
        session?.cancel()
        session = nil
        closed?()
        closed = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    // MARK: - 部品(単体テストで確かめる)

    nonisolated static func authorizeURL(clientID: String?, hostID: String, redirectURI: String, state: String, nonce: String,
                                         challenge: String) -> URL {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID ?? ChatGPTConfig.registrationClientID),
        ]
        // アプリの名前は最初の登録の時だけ送る。
        if clientID == nil { items.append(URLQueryItem(name: "agent_name_hint", value: ChatGPTConfig.agentName)) }
        items += [
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: ChatGPTConfig.scopes),
            URLQueryItem(name: "resource", value: ChatGPTConfig.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        var components = URLComponents(url: ChatGPTConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // `+` などを確実に符号化する(URLComponents は `+` を残す)。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// PKCE の S256: SHA-256 の base64url(詰め物なし)。
    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 戻り先に届いた要求の中身。
    nonisolated struct Callback: Sendable, Equatable {
        var code: String?
        var state: String?
        var clientID: String?
        var error: String?
        var errorDescription: String?

        /// `GET /auth/callback?code=...&state=... HTTP/1.1` の 1 行目から読む。戻り先の道でなければ nil。
        static func parse(requestLine: String) -> Callback? {
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
                  components.path == ChatGPTConfig.callbackPath else { return nil }
            let value = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
            return Callback(code: value("code"), state: value("state"), clientID: value("client_id"), error: value("error"),
                            errorDescription: value("error_description"))
        }
    }
}

/// `127.0.0.1` の 1 回きりの待ち受け。戻り先の道への GET を 1 つ受け取って返事をする。
nonisolated final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "struis.chatgpt.loopback")
    private let lock = NSLock()
    private var waiter: CheckedContinuation<ChatGPTSignIn.Callback, Error>?
    private var received: ChatGPTSignIn.Callback?
    private var expectedState: String?

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// 並べたポートを順に試し、最初に開けたものを使う。
    static func open(ports: [UInt16]) async throws -> LoopbackListener {
        for port in ports {
            if let opened = try? await open(port: port) { return opened }
        }
        throw ChatGPTSignIn.Failure.noPort
    }

    private static func open(port: UInt16) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let opened = LoopbackListener(listener: listener, port: port)
        try await opened.start()
        return opened
    }

    private func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                case .cancelled: if once.take() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var hasCallback: Bool { lock.withLock { received != nil } }

    func stop() {
        listener.cancel()
        lock.withLock {
            waiter?.resume(throwing: CancellationError())
            waiter = nil
        }
    }

    func waitForCallback(expectedState: String) async throws -> ChatGPTSignIn.Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.expectedState = expectedState
                    if let received {
                        continuation.resume(returning: received)
                    } else {
                        waiter = continuation
                    }
                }
            }
        } onCancel: {
            lock.withLock {
                waiter?.resume(throwing: CancellationError())
                waiter = nil
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            guard text.contains("\r\n\r\n") || complete || error != nil || buffer.count > 64 * 1024 else {
                return self.read(connection, buffer: buffer)
            }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            guard let callback = ChatGPTSignIn.Callback.parse(requestLine: line) else {
                // favicon などは 404 で返す。
                return self.respond(connection, status: "404 Not Found", body: "")
            }
            let succeeded = self.lock.withLock { callback.error == nil && callback.code != nil && callback.state == self.expectedState }
            self.respond(connection, status: "200 OK", body: Self.page(succeeded: succeeded))
            self.lock.withLock {
                guard self.received == nil else { return }
                self.received = callback
                self.waiter?.resume(returning: callback)
                self.waiter = nil
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// ブラウザに返すページ(すぐにアプリが画面を閉じるので、見えるのは一瞬)。
    static func page(succeeded: Bool) -> String {
        let mark = succeeded
            ? "<div class=\"mark ok\"><svg width=\"26\" height=\"26\" viewBox=\"0 0 26 26\" fill=\"none\" stroke=\"#f5f0e6\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"m5 13.5 5.5 5.5L21 7.5\"/></svg></div>"
            : "<div class=\"mark ng\"><svg width=\"22\" height=\"22\" viewBox=\"0 0 22 22\" fill=\"none\" stroke=\"#c07060\" stroke-width=\"3\" stroke-linecap=\"round\"><path d=\"M5 5l12 12M17 5 5 17\"/></svg></div>"
        let text = succeeded ? "<h1>サインインできました</h1>" : "<h1>サインインできませんでした</h1><p>Struis でやり直してください</p>"
        return """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Struis</title>
        <style>body{margin:0;background:#f5f0e6;color:#1f1a14;font-family:-apple-system,sans-serif;font-weight:500;display:flex;min-height:100vh;align-items:center;justify-content:center}
        .card{background:linear-gradient(#fffdf9,#fbf7ef);border:1px solid rgba(0,0,0,.08);border-radius:22px;padding:40px 24px;margin:20px;display:flex;flex-direction:column;align-items:center;gap:14px;min-width:260px}
        .mark{width:56px;height:56px;border-radius:28px;display:flex;align-items:center;justify-content:center}.ok{background:#3f8f62}.ng{background:rgba(192,112,96,.16)}
        h1{font-size:20px;margin:0}p{margin:0;color:#5a5044;font-size:15px}
        @media (prefers-color-scheme:dark){body{background:#1d1915;color:#efe5d2}.card{background:linear-gradient(#2d2821,#27221c)}p{color:#aea18c}}</style></head>
        <body><div class="card">\(mark)\(text)</div></body></html>
        """
    }
}

/// 1 回だけ真を返す(continuation を 2 回再開しないため)。
nonisolated private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
#endif

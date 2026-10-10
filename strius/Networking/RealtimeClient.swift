import Foundation

@MainActor
final class RealtimeClient {
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    private var reconnectLoop: Task<Void, Never>?
    private var continuation: AsyncStream<RealtimeEvent>.Continuation?

    private weak var client: APIClient?
    private var isStarted = false
    private var attempt = 0

    func events(client: APIClient) -> AsyncStream<RealtimeEvent> {
        self.client = client
        return AsyncStream { continuation in
            self.continuation = continuation
            self.isStarted = true
            Task { await self.connect() }
            let terminate = { [weak self] in self?.stop() }
            continuation.onTermination = { _ in
                Task { @MainActor in terminate() }
            }
        }
    }

    func stop() {
        isStarted = false
        receiveLoop?.cancel()
        heartbeatLoop?.cancel()
        reconnectLoop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func connect() async {
        guard isStarted, let client else { return }
        let ticket: RealtimeTicketResponse
        do {
            ticket = try await client.send(.realtimeTicket)
        } catch {
            await handleDisconnect()
            return
        }

        var request = URLRequest(url: ServerConfig.realtimeURL)
        request.setValue(
            "struis, struis-ticket.\(ticket.token)",
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        attempt = 0
        startReceiveLoop(task: task)
        startHeartbeat(task: task)
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    await self.handle(message: message)
                } catch {
                    await self?.handleDisconnect()
                    return
                }
            }
        }
    }

    private func startHeartbeat(task: URLSessionWebSocketTask) {
        heartbeatLoop?.cancel()
        heartbeatLoop = Task { [weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let task else { return }
                do {
                    try await task.send(.string("ping"))
                } catch {
                    return
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            if let event = RealtimeEvent.decode(from: text) {
                continuation?.yield(event)
            }
        case .data:
            break
        @unknown default:
            break
        }
    }

    private func handleDisconnect() async {
        guard isStarted else { return }
        attempt = min(attempt + 1, 10)
        let delay = min(Double(1 << attempt), 30.0)
        reconnectLoop?.cancel()
        reconnectLoop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.connect()
        }
    }
}

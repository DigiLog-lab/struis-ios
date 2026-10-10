import XCTest
import UIKit
import PDFKit
import Network
import CryptoKit
import ImageIO
@testable import strius

/// Test-owned HTTP endpoint, bound only to loopback. It drains the actual JSON
/// request without retaining its body, then returns a complete HTTP 503. No
/// model response or app-server protocol is simulated.
nonisolated private final class NativePdfFailureEndpoint: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "native.pdf.failure-endpoint")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var didReceiveRequest = false
    private var stopped = false
    private var startResolved = false
    var receivedRequest: Bool { lock.lock(); defer { lock.unlock() }; return didReceiveRequest }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<UInt16, Error>
                switch state {
                case .ready:
                    if let port = self.listener.port { result = .success(port.rawValue) }
                    else { result = .failure(CodexAppServerError.malformed("loopback listener has no port")) }
                case .failed(let error), .waiting(let error): result = .failure(error)
                default: return
                }
                self.lock.lock()
                guard !self.startResolved else { self.lock.unlock(); return }
                self.startResolved = true
                self.lock.unlock()
                self.listener.stateUpdateHandler = nil
                if case .failure = result { self.listener.cancel() }
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let active = connections
        connections.removeAll()
        lock.unlock()
        listener.cancel()
        active.forEach { $0.cancel() }
    }

    nonisolated private final class Request: @unchecked Sendable {
        // All request parsing runs on the endpoint's serial queue.
        var header = Data()
        var remaining: Int?
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if stopped { lock.unlock(); connection.cancel(); return }
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, request: Request())
    }

    private func receive(_ connection: NWConnection, request: Request) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            if let data {
                if let remaining = request.remaining {
                    request.remaining = remaining - data.count
                } else {
                    request.header.append(data)
                    guard request.header.count <= 128 * 1024 else { connection.cancel(); return }
                    if let end = request.header.range(of: Data("\r\n\r\n".utf8)) {
                        let header = String(decoding: request.header[..<end.lowerBound], as: UTF8.self)
                        let length = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                            let pair = line.split(separator: ":", maxSplits: 1)
                            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
                            return Int(pair[1].trimmingCharacters(in: .whitespaces))
                        }.first
                        guard header.hasPrefix("POST /v1/responses "), let length, (1...32 * 1024 * 1024).contains(length) else {
                            connection.cancel(); return
                        }
                        request.remaining = length - (request.header.count - end.upperBound)
                        request.header.removeAll(keepingCapacity: false)
                    }
                }
                if let remaining = request.remaining, remaining <= 0 {
                    self.lock.lock(); self.didReceiveRequest = true; self.lock.unlock()
                    let body = Data("{\"error\":{\"message\":\"Intentional local test failure\",\"type\":\"server_error\"}}".utf8)
                    var response = Data("HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(body)
                    connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            guard error == nil, !complete else { connection.cancel(); return }
            self.receive(connection, request: request)
        }
    }
}

/// Runs the shipped native worker on Simulator. No command output is mocked.
final class NativeRuntimeLiveTests: XCTestCase {
    private enum MemoryPhase: String { case start, beforeImage = "before_image", afterImage = "after_image", afterMath = "after_math" }

    @MainActor
    private func recordMemory(_ reply: NativeRuntimeReply, role: NativeMemoryObservation.Role, phase: MemoryPhase) throws {
        let sample = try XCTUnwrap(reply.memoryObservation, "worker structured memory measurement missing")
        XCTAssertTrue(sample.matches(reply: reply, identity: reply.workerID, role: role))
        XCTAssertEqual(sample.clockStatus, 0)
        XCTAssertEqual(sample.queryStatus, 0)
        XCTAssertGreaterThan(try XCTUnwrap(sample.monotonicNanoseconds), 0)
        let footprint = try XCTUnwrap(sample.footprintBytes, "worker footprint measurement missing")
        let available = try XCTUnwrap(sample.availableBytes, "worker available-memory measurement missing")
        XCTAssertEqual(footprint, reply.memoryFootprintBytes)
        XCTAssertEqual(available, reply.availableMemoryBytes)
        XCTAssertGreaterThan(footprint, 0)
        if let peak = sample.lifetimePeakFootprintBytes { XCTAssertGreaterThanOrEqual(peak, footprint) }
        let host = NativeRuntimeHost.shared.hostMemoryObservation()
        XCTAssertEqual(host.pid, getpid())
        XCTAssertEqual(host.role, .host)
        XCTAssertGreaterThan(try XCTUnwrap(host.footprintBytes), 0)
        // An endpoint observation only. Host state is read at record time and does not
        // certify the worker's earlier sampling interval or background execution.
        let hostState: String
        switch UIApplication.shared.applicationState {
        case .active: hostState = "active"
        case .inactive: hostState = "inactive"
        case .background: hostState = "background"
        @unknown default: hostState = "unknown"
        }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        for observation in [sample, host] {
            let current = observation.footprintBytes.map { String($0) } ?? "unavailable"
            let peak = observation.lifetimePeakFootprintBytes.map { String($0) } ?? "unavailable"
            let free = observation.availableBytes.map { String($0) } ?? "unavailable"
            let timestamp = observation.monotonicNanoseconds.map { String($0) } ?? "unavailable"
            print("NATIVE_MEMORY_ENDPOINT role=\(observation.role.rawValue) phase=\(phase.rawValue) pid=\(observation.pid) identity=\(observation.identity) monotonic_ns=\(timestamp) footprint_bytes=\(current) process_lifetime_peak_bytes=\(peak) available_bytes=\(free) query_status=\(observation.queryStatus) query_count=\(observation.queryCount) host_state_at_record=\(hostState) simulator=\(simulator)")
        }
    }

    @MainActor
    func testPdfThumbnailLimitUsesBackingPixelsAcrossDisplayScales() throws {
        for size in [CGSize(width: 800, height: 600), CGSize(width: 600, height: 800)] {
            for scale in [CGFloat(1), CGFloat(2), CGFloat(3)] {
                try autoreleasepool {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = scale
                    let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { context in
                        UIColor.white.setFill()
                        context.cgContext.fill(CGRect(origin: .zero, size: size))
                        UIColor.black.setFill()
                        context.cgContext.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
                    }
                    let originalPixels = try XCTUnwrap(thumbnail.cgImage)
                    XCTAssertEqual(max(originalPixels.width, originalPixels.height), Int(800 * scale))
                    let bytes = try XCTUnwrap(ChatStore.pdfThumbnailJPEG(thumbnail))
                    let result = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
                    XCTAssertEqual(max(result.width, result.height), min(1600, Int(800 * scale)))
                    XCTAssertEqual(Double(result.width) / Double(result.height), Double(size.width / size.height), accuracy: 0.002)
                    if scale <= 2 {
                        XCTAssertEqual(bytes, thumbnail.jpegData(compressionQuality: 0.8), "既存のpixel制限内の画像を追加でリサイズ・再エンコードしない")
                    }
                    print("NATIVE_PDF_PIXEL_LIMIT input=\(originalPixels.width)x\(originalPixels.height) scale=\(scale) output=\(result.width)x\(result.height)")
                }
            }
        }
    }

    @MainActor
    private func legacyPageFixture(directory: URL, name: String, size: CGSize, orientation: Int = 1,
                                   kind: String = ChatTurns.Attachment.pageImageKind) throws -> (ChatTurns.Attachment, Data) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = encoded as Data
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file, options: .atomic)
        let relative = directory.lastPathComponent + "/" + name
        return (.init(filename: name, contentType: "image/jpeg", bytes: bytes.count, relativePath: relative,
                      sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), kind: kind), bytes)
    }

    @MainActor
    func testLegacyPdfPagesProduceReusableBoundedDerivativesWithoutChangingOriginals() throws {
        let directory = ChatTurns.attachmentsRoot.appendingPathComponent("legacy-page-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, fixture) in [(CGSize(width: 2400, height: 1800), 1),
                                  (CGSize(width: 1800, height: 2400), 1),
                                  (CGSize(width: 2400, height: 1800), 6)].enumerated() {
            try autoreleasepool {
                let (attachment, original) = try legacyPageFixture(directory: directory, name: "page-\(index).jpg",
                                                                  size: fixture.0, orientation: fixture.1)
                let originalMetadata = attachment.json
                let derived = try ChatStore.runtimePageImageAttachment(attachment)
                let derivedURL = ChatTurns.attachmentsRoot.appendingPathComponent(derived.relativePath)
                defer {
                    try? FileManager.default.removeItem(at: derivedURL)
                    try? FileManager.default.removeItem(at: derivedURL.appendingPathExtension("sha256"))
                }
                XCTAssertNotEqual(derived.relativePath, attachment.relativePath)
                XCTAssertEqual(derived.filename, attachment.filename)
                XCTAssertEqual(derived.kind, ChatTurns.Attachment.pageImageKind)
                let bytes = try Data(contentsOf: derivedURL)
                let pixels = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
                XCTAssertEqual(max(pixels.width, pixels.height), 1600)
                let expectedRatio = fixture.1 == 6 ? Double(fixture.0.height / fixture.0.width) : Double(fixture.0.width / fixture.0.height)
                XCTAssertEqual(Double(pixels.width) / Double(pixels.height), expectedRatio, accuracy: 0.002)
                XCTAssertEqual(derived.bytes, bytes.count)
                XCTAssertEqual(derived.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
                let modified = try derivedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let reused = try ChatStore.runtimePageImageAttachment(attachment)
                XCTAssertEqual(reused, derived)
                XCTAssertEqual(try Data(contentsOf: derivedURL), bytes)
                XCTAssertEqual(try derivedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified,
                               "A retry reuses the derivative instead of re-encoding it")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(attachment.filename)), original)
                XCTAssertEqual(attachment.json, originalMetadata)
            }
        }
    }

    @MainActor
    func testBoundedPageAndOversizedPhotoKeepTheirOriginalReferencesAndBytes() throws {
        let directory = ChatTurns.attachmentsRoot.appendingPathComponent("unchanged-page-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, size, kind) in [("bounded.jpg", CGSize(width: 1600, height: 1200), ChatTurns.Attachment.pageImageKind),
                                   ("small.jpg", CGSize(width: 800, height: 600), ChatTurns.Attachment.pageImageKind),
                                   ("photo.jpg", CGSize(width: 2400, height: 1800), "image")] {
            let (attachment, original) = try legacyPageFixture(directory: directory, name: name, size: size, kind: kind)
            XCTAssertEqual(try ChatStore.runtimePageImageAttachment(attachment), attachment)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), original)
        }
    }

    /// Compose uses the same stored metadata as send/retry/recovery, without any
    /// native response fixture or model authentication. Only input staging is exercised.
    @MainActor
    func testComposeStagesLegacyPdfDerivativeWithMatchingManifestAndPreservedLedger() async throws {
        let directory = ChatTurns.attachmentsRoot.appendingPathComponent("compose-page-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deskBackup = directory.appendingPathComponent("desk-backup", isDirectory: true)
        let hadDesk = FileManager.default.fileExists(atPath: ChatTurns.desk.path)
        if hadDesk { try FileManager.default.copyItem(at: ChatTurns.desk, to: deskBackup) }
        defer {
            try? FileManager.default.removeItem(at: ChatTurns.desk)
            if hadDesk { try? FileManager.default.copyItem(at: deskBackup, to: ChatTurns.desk) }
        }
        let (attachment, original) = try legacyPageFixture(directory: directory, name: "fixture-p1.jpg", size: CGSize(width: 2400, height: 1800))
        let pdfURL = directory.appendingPathComponent("fixture.pdf")
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 240, height: 180))
        let pdf = pdfRenderer.pdfData { context in context.beginPage(); UIColor.white.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 240, height: 180)) }
        try pdf.write(to: pdfURL)
        let document = ChatTurns.Attachment(filename: "fixture.pdf", contentType: "application/pdf", bytes: pdf.count,
                                            relativePath: directory.lastPathComponent + "/fixture.pdf",
                                            sha256: SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined(), kind: "document")
        let ledger = try Ledger.inMemory()
        let threadID = LedgerID.make(), userID = LedgerID.make(), assistantID = LedgerID.make()
        let metadata: LedgerJSON = .object(["attachments": .array([document.json, attachment.json])])
        try await ledger.append([
            ChatRepository.createThread(id: threadID, title: "legacy attachment fixture").1,
            ChatRepository.createMessage(id: userID, threadID: threadID, role: "user", status: "completed", plainText: "fixture question",
                                         blocks: .emptyArray, metadata: metadata).1,
        ])
        let assets = AssetCache(root: directory.appendingPathComponent("assets", isDirectory: true), lenient: true)
        var previousImage: TurnPlan.ImageRef?
        var derivedURL: URL?
        defer {
            if let derivedURL {
                try? FileManager.default.removeItem(at: derivedURL)
                try? FileManager.default.removeItem(at: derivedURL.appendingPathExtension("sha256"))
            }
        }
        for _ in 0..<2 {
            let rows = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
            let stored = try XCTUnwrap(rows.first { $0.id == userID })
            let attachments = (stored.metadata["attachments"]?.arrayValue ?? []).compactMap(ChatTurns.Attachment.init(json:))
            XCTAssertEqual(attachments, [document, attachment])
            var state = ChatTurns.State(turnID: LedgerID.make(), threadID: threadID, userMessageID: userID, assistantMessageID: assistantID,
                                        learnerID: "fixture-learner", text: "fixture question", attachments: attachments, workbookView: nil,
                                        codexThreadID: nil, progressBefore: ProgressState(), progressAfter: ProgressState())
            let plan = try await ChatTurns.compose(ledger: ledger, assets: assets, state: &state, roundText: nil)
            defer { WorkspaceStager.cleanup(plan: plan) }
            let turn = try XCTUnwrap(plan.turn)
            XCTAssertEqual(turn.images.count, 1)
            let image = try XCTUnwrap(turn.images.first)
            XCTAssertNotEqual(image.hostPath, directory.appendingPathComponent(attachment.filename).path)
            if let previousImage { XCTAssertEqual(image, previousImage) }
            previousImage = image
            derivedURL = URL(fileURLWithPath: image.hostPath)
            let bytes = try Data(contentsOf: try XCTUnwrap(derivedURL))
            let pixels = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
            XCTAssertEqual(max(pixels.width, pixels.height), 1600)
            XCTAssertEqual(Double(pixels.width) / Double(pixels.height), 4.0 / 3.0, accuracy: 0.002)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let manifest = try XCTUnwrap(plan.workspace.files.first { $0.path.hasSuffix("/manifest.md") }?.inline)
            // ページの画像は持ち主の PDF の節に、総ページ数と struis.document の案内と一緒に書く(信頼性計画 P3)。
            XCTAssertTrue(manifest.contains("- page_images: `\(image.path)` (page 1)"))
            XCTAssertTrue(manifest.contains("- pages: `1`"))
            XCTAssertTrue(manifest.contains("struis.document"))
            XCTAssertTrue(manifest.contains("- sha256: `\(document.sha256)`"))
            XCTAssertFalse(hash.isEmpty)
            XCTAssertTrue(plan.workspace.copies?.contains { $0.hostPath == pdfURL.path } == true)
            try WorkspaceStager.prepare(plan: plan, assets: assets)
            XCTAssertEqual(try Data(contentsOf: plan.hostWorkspace.appendingPathComponent(image.path)), bytes,
                           "The actual staged model image must match the derived input bytes")
            let manifestPath = try XCTUnwrap(plan.workspace.files.first { $0.path.hasSuffix("/manifest.md") }?.path)
            XCTAssertEqual(try String(contentsOf: plan.hostWorkspace.appendingPathComponent(manifestPath), encoding: .utf8), manifest)
            let stagedDocument = try XCTUnwrap(plan.workspace.copies?.first { $0.hostPath == pdfURL.path })
            XCTAssertEqual(try Data(contentsOf: plan.hostWorkspace.appendingPathComponent(stagedDocument.path)), pdf)
            XCTAssertEqual(try Data(contentsOf: pdfURL), pdf)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(attachment.filename)), original)
            XCTAssertEqual(stored.metadata, metadata)
        }
        let rowsAfterCompose = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
        XCTAssertEqual(try XCTUnwrap(rowsAfterCompose.first { $0.id == userID }).metadata, metadata)
    }

    /// Real pinned fs/readFile supplies a response beyond Foundation's default
    /// 1 MiB limit. Compare the old failure and configured production transport;
    /// no model authentication or mocked WebSocket is involved.
    @MainActor
    func testLargeNativeRpcResponseKeepsSessionConnected() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        let directory = HyotanBoot.workspaceRoot.appendingPathComponent("large-rpc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.bin")
        let expected = Data(repeating: 0x5a, count: 1_000_000)
        try expected.write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = CodexAppServerSession(clientVersion: "native-large-rpc", launcher: CodexAppServerSession.nativeLauncher(boot: boot, maximumMessageSize: 1_048_576))
        do {
            try await old.start()
            do {
                _ = try await old.request("fs/readFile", params: ["path": file.path])
                XCTFail("1 MiBの旧上限が1.33 MiBの実RPC応答を受理した")
            } catch let error as CodexAppServerError {
                guard case .closed(let diagnostic) = error else { throw error }
                XCTAssertTrue(diagnostic.contains("stage=receive"), diagnostic)
                XCTAssertTrue(diagnostic.contains("receive_limit=1048576"), diagnostic)
                print("NATIVE_RPC_OLD_LIMIT_FAILURE \(diagnostic)")
            }
        } catch {
            await old.close()
            NativeRuntimeHost.shared.stop()
            await NativeRuntimeHost.shared.waitForRetirement()
            throw error
        }
        await old.close()
        NativeRuntimeHost.shared.stop()
        await NativeRuntimeHost.shared.waitForRetirement()

        let session = CodexAppServerSession(clientVersion: "native-large-rpc", launcher: CodexAppServerSession.nativeLauncher(boot: boot))
        do {
            try await session.start()
            let generation = await session.generation
            let response = try await session.request("fs/readFile", params: ["path": file.path])
            let base64 = try XCTUnwrap(response["dataBase64"] as? String)
            XCTAssertGreaterThan(base64.utf8.count, 1_048_576)
            XCTAssertEqual(Data(base64Encoded: base64), expected)
            _ = try await session.request("account/read", params: ["refreshToken": false])
            let after = await session.generation
            XCTAssertEqual(after, generation, "大きな応答の後にも同じsessionで応答する")
            print("NATIVE_RPC_LARGE_RESPONSE bytes=\(expected.count) base64_bytes=\(base64.utf8.count) same_generation=\(after == generation)")
        } catch {
            await session.close()
            NativeRuntimeHost.shared.stop()
            await NativeRuntimeHost.shared.waitForRetirement()
            throw error
        }
        await session.close()
        NativeRuntimeHost.shared.stop()
        await NativeRuntimeHost.shared.waitForRetirement()
    }

    /// Exercise real PDF rasterization, Codex image preparation and persistent
    /// resume. The provider deliberately returns an owned loopback HTTP failure, so a
    /// sampling failure is expected and is never counted as a model response.
    @MainActor
    func testPdfImagePreparationAndColdResumeKeepNativeServerAlive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        let directory = HyotanBoot.workspaceRoot.appendingPathComponent("pdf-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(bounds)
            for row in 0..<80 {
                for column in 0..<60 {
                    UIColor(red: CGFloat((row * 17 + column * 31) % 255) / 255, green: CGFloat((row * 37 + column * 13) % 255) / 255, blue: CGFloat((row * 23 + column * 47) % 255) / 255, alpha: 1).setFill()
                    context.cgContext.fill(CGRect(x: CGFloat(column * 10), y: CGFloat(row * 9), width: 7, height: 6))
                }
            }
        }
        let page = try XCTUnwrap(PDFDocument(data: pdf)?.page(at: 0))
        let thumbnailSize = CGSize(width: bounds.width * 1600 / bounds.height, height: 1600)
        let thumbnail = page.thumbnail(of: thumbnailSize, for: .mediaBox)
        let thumbnailPixels = try XCTUnwrap(thumbnail.cgImage)
        print("NATIVE_PDF_THUMBNAIL pixels=\(thumbnailPixels.width)x\(thumbnailPixels.height) scale=\(thumbnail.scale)")
        let pdfURL = directory.appendingPathComponent("source.pdf")
        try pdf.write(to: pdfURL)
        let pages = ChatStore.pdfPageImages(at: pdfURL)
        XCTAssertEqual(pages.count, 1)
        let jpeg = try XCTUnwrap(pages.first?.jpeg)
        let inputPixels = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        print("NATIVE_PDF_INPUT pixels=\(inputPixels.width)x\(inputPixels.height) jpeg_bytes=\(jpeg.count)")
        XCTAssertTrue(DocumentReader.fitsModelBudget(width: inputPixels.width, height: inputPixels.height), "PDFのページ画像はJPEGの実pixelでCodexの枠に収める")
        let image = directory.appendingPathComponent("page.jpg")
        try jpeg.write(to: image)
        let endpoint = try NativePdfFailureEndpoint()
        let port = try await endpoint.start()
        defer { endpoint.stop() }
        let config: JSONObject = [
            "model_provider": "image_probe",
            "model_providers.image_probe": ["name": "Unavailable loopback probe", "base_url": "http://127.0.0.1:\(port)/v1", "wire_api": "responses", "requires_openai_auth": false, "supports_websockets": false, "request_max_retries": 0, "stream_max_retries": 0],
        ]
        let session = CodexAppServerSession(clientVersion: "native-pdf-probe", launcher: CodexAppServerSession.nativeLauncher(boot: boot))
        var threadID = ""
        var rolloutPath: String?
        do {
            try await session.start()
            try recordMemory(try await NativeRuntimeHost.shared.codexWorkerHealth(), role: .codex, phase: .beforeImage)
            let generation = await session.generation
            let started = try await session.request("thread/start", params: ["cwd": directory.path, "model": "gpt-6-astra", "modelProvider": "image_probe", "allowProviderModelFallback": false, "approvalPolicy": "never", "sandbox": "danger-full-access", "ephemeral": false, "persistExtendedHistory": true, "config": config])
            XCTAssertEqual(started["modelProvider"] as? String, "image_probe", "検査用loopback providerが実際に選ばれたことを確認する")
            print("NATIVE_PDF_PROVIDER configured=\(started["modelProvider"] as? String == "image_probe")")
            let thread = try XCTUnwrap(started["thread"] as? JSONObject)
            threadID = try XCTUnwrap(thread["id"] as? String)
            let rollout = try XCTUnwrap(thread["path"] as? String)
            rolloutPath = rollout
            let response = try await session.request("turn/start", params: ["threadId": threadID, "input": [["type": "text", "text": "Image processing probe; the model endpoint is unavailable."], ["type": "localImage", "path": image.path]]])
            let turnID = try XCTUnwrap((response["turn"] as? JSONObject)?["id"] as? String)
            let expectedThread = threadID
            let deadline = Date().addingTimeInterval(90)
            var completion: CodexAppServerSession.Notification?
            while completion == nil {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw CodexAppServerError.timeout("turn/completed") }
                let event = try await session.waitForNotification(methods: ["turn/started", "item/started", "item/completed", "error", "turn/completed"], timeout: .milliseconds(Int(remaining * 1000))) {
                    $0["threadId"] as? String == expectedThread
                }
                // Only fixed method names, known item kinds and booleans are logged.
                let item = (event.params["item"] as? JSONObject)?["type"] as? String ?? "none"
                let safeItem = ["userMessage", "agentMessage", "reasoning", "plan", "commandExecution", "none"].contains(item) ? item : "other"
                print("NATIVE_PDF_EVENT method=\(event.method) item=\(safeItem) will_retry=\(event.params["willRetry"] as? Bool == true)")
                if event.method == "turn/completed", (event.params["turn"] as? JSONObject)?["id"] as? String == turnID { completion = event }
            }
            let completed = try XCTUnwrap(completion)
            XCTAssertTrue(endpoint.receivedRequest, "実Codexが検査用loopback endpointへ要求したことを必須にする")
            print("NATIVE_PDF_ENDPOINT request_received=\(endpoint.receivedRequest)")
            XCTAssertEqual((completed.params["turn"] as? JSONObject)?["status"] as? String, "failed", "接続できない検査用providerを実応答の成功にしない")
            // The rollout lives in the app's private Codex home, outside the workspace capability
            // that serves fs/*; the trusted app reads it directly.
            let data = try Data(contentsOf: URL(fileURLWithPath: rollout))
            var preparedImages = 0
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject,
                      entry["type"] as? String == "response_item", let payload = entry["payload"] as? JSONObject,
                      payload["type"] as? String == "message", payload["role"] as? String == "user" else { continue }
                for item in payload["content"] as? [JSONObject] ?? [] {
                    guard item["type"] as? String == "input_image", let url = item["image_url"] as? String else { continue }
                    XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"), "実image loaderの準備済みJPEGを確認する")
                    let bytes = try XCTUnwrap(Data(base64Encoded: String(url.split(separator: ",", maxSplits: 1).last ?? "")))
                    let prepared = try XCTUnwrap(UIImage(data: bytes))
                    XCTAssertGreaterThan(prepared.size.width, 0)
                    XCTAssertGreaterThan(prepared.size.height, 0)
                    let pixels = try XCTUnwrap(prepared.cgImage)
                    print("NATIVE_PDF_PREPARED pixels=\(pixels.width)x\(pixels.height)")
                    preparedImages += 1
                }
            }
            XCTAssertGreaterThanOrEqual(preparedImages, 1, "実Codexが画像を処理しrolloutへ保持した証拠を必須にする")
            _ = try await session.request("account/read", params: ["refreshToken": false])
            let after = await session.generation
            XCTAssertEqual(after, generation)
            print("NATIVE_PDF_IMAGE_PREPARED jpeg_bytes=\(jpeg.count) prepared_images=\(preparedImages) sampling_failed_expected=true same_generation=\(after == generation)")
            try recordMemory(try await NativeRuntimeHost.shared.codexWorkerHealth(), role: .codex, phase: .afterImage)
        } catch {
            print("NATIVE_PDF_FAILURE endpoint_request_received=\(endpoint.receivedRequest)")
            let failureGeneration = await session.generation
            let running = await session.isRunning
            if running {
                do {
                    _ = try await session.request("account/read", params: ["refreshToken": false], timeout: .seconds(5))
                    let after = await session.generation
                    print("NATIVE_PDF_FAILURE account_read=true same_generation=\(after == failureGeneration)")
                } catch { print("NATIVE_PDF_FAILURE account_read=false") }
            } else { print("NATIVE_PDF_FAILURE running=false") }
            if let rolloutPath, let data = try? Data(contentsOf: URL(fileURLWithPath: rolloutPath)) {
                var images = 0
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject,
                          entry["type"] as? String == "response_item", let payload = entry["payload"] as? JSONObject else { continue }
                    images += (payload["content"] as? [JSONObject] ?? []).filter { $0["type"] as? String == "input_image" }.count
                }
                print("NATIVE_PDF_FAILURE rollout_bytes=\(data.count) recorded_images=\(images)")
            }
            let stderr = HyotanBoot.root.deletingLastPathComponent().appendingPathComponent("Library/worker-stderr.log")
            if let data = try? Data(contentsOf: stderr), let text = String(data: data.suffix(256 * 1024), encoding: .utf8) {
                print("NATIVE_PDF_FAILURE stderr_tail_may_include_previous_tests=true stderr_tail_missing_credentials=\(text.localizedCaseInsensitiveContains("missing credentials") || text.localizedCaseInsensitiveContains("missing api key")) stderr_tail_connection_refused=\(text.localizedCaseInsensitiveContains("connection refused")) stderr_tail_prewarm=\(text.localizedCaseInsensitiveContains("prewarm"))")
            }
            await session.close()
            NativeRuntimeHost.shared.stop()
            await NativeRuntimeHost.shared.waitForRetirement()
            throw error
        }
        await session.close()
        NativeRuntimeHost.shared.stop()
        await NativeRuntimeHost.shared.waitForRetirement()
        let resumed = CodexAppServerSession(clientVersion: "native-pdf-resume", launcher: CodexAppServerSession.nativeLauncher(boot: boot))
        do {
            try await resumed.start()
            let response = try await resumed.request("thread/resume", params: ["threadId": threadID, "cwd": directory.path, "modelProvider": "image_probe", "allowProviderModelFallback": false, "config": config, "persistExtendedHistory": true, "excludeTurns": true])
            let thread = try XCTUnwrap(response["thread"] as? JSONObject)
            XCTAssertEqual(thread["id"] as? String, threadID)
            XCTAssertTrue((thread["turns"] as? [JSONObject] ?? []).isEmpty, "未使用の返信履歴を展開しない")
            // Query persisted history separately to prove excludeTurns did not erase it.
            let restored = try await resumed.request("thread/read", params: ["threadId": threadID, "includeTurns": true])
            let restoredThread = try XCTUnwrap(restored["thread"] as? JSONObject)
            XCTAssertFalse((restoredThread["turns"] as? [JSONObject] ?? []).isEmpty, "画像turnの履歴保存・復元を維持する")
            _ = try await resumed.request("account/read", params: ["refreshToken": false])
            print("NATIVE_PDF_COLD_RESUME history_present=true account_read=true")
        } catch {
            await resumed.close()
            NativeRuntimeHost.shared.stop()
            await NativeRuntimeHost.shared.waitForRetirement()
            throw error
        }
        await resumed.close()
        NativeRuntimeHost.shared.stop()
        await NativeRuntimeHost.shared.waitForRetirement()
    }

    /// Opening unit creation warms the server before the learner finishes the questions.
    /// Exercise that idle interval without a model response or an authentication fixture.
    @MainActor
    func testAppServerRemainsConnectedAfterIdle() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        let session = CodexAppServerSession(clientVersion: "native-idle-test", launcher: CodexAppServerSession.nativeLauncher(boot: boot))
        do {
            try await session.start()
            let generation = await session.generation
            _ = try await session.request("account/read", params: ["refreshToken": false])
            try await Task.sleep(for: .seconds(8))
            try await session.ensureHealthy()
            _ = try await session.request("account/read", params: ["refreshToken": false])
            let after = await session.generation
            XCTAssertEqual(after, generation, "待機中にapp-serverの接続が閉じ、再起動された")
            print("NATIVE_APP_SERVER_IDLE seconds=8 same_generation=\(after == generation)")
        } catch {
            await session.close()
            NativeRuntimeHost.shared.stop()
            throw error
        }
        await session.close()
        NativeRuntimeHost.shared.stop()
    }

    /// iOS reclaims a suspended app's listening socket while the in-process server keeps running.
    /// Moving to a new listener must keep open connections and accept new ones on the new port only.
    @MainActor
    func testInProcessServerListensAgainAfterListenerReplacement() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        let kept = CodexAppServerSession(clientVersion: "native-rebind-open", launcher: CodexAppServerSession.nativeLauncher(boot: boot))
        let next = CodexAppServerSession(clientVersion: "native-rebind-next", launcher: CodexAppServerSession.nativeLauncher(boot: boot))
        do {
            try await kept.start()
            _ = try await kept.request("account/read", params: ["refreshToken": false])
            let first = try XCTUnwrap(NativeRuntimeHost.shared.rebindInProcessListener())
            let second = try XCTUnwrap(NativeRuntimeHost.shared.rebindInProcessListener())
            XCTAssertNotEqual(first, second)
            var refused = false
            for _ in 0..<50 where !refused {
                refused = !Self.loopbackAccepts(port: first)
                if !refused { try await Task.sleep(for: .milliseconds(100)) }
            }
            XCTAssertTrue(refused, "置き換え前の待受がまだ接続を受け付けている")
            _ = try await kept.request("account/read", params: ["refreshToken": false])
            try await next.start()
            _ = try await next.request("account/read", params: ["refreshToken": false])
            print("NATIVE_LISTENER_REPLACED old_refused=\(refused) open_connection_kept=1 new_port_accepts=1")
        } catch {
            await kept.close(); await next.close()
            NativeRuntimeHost.shared.stop()
            throw error
        }
        await kept.close(); await next.close()
        NativeRuntimeHost.shared.stop()
    }

    private static func loopbackAccepts(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    @MainActor
    func testSimulatorFileBoundaryObservation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        let host = NativeRuntimeHost.shared
        _ = try await host.start { _ in }
        defer { host.stop() }
        let workspace = HyotanBoot.workspaceRoot.appendingPathComponent("boundary-" + UUID().uuidString)
        let canary = FileManager.default.temporaryDirectory.appendingPathComponent("private-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("private-canary".utf8).write(to: canary)
        defer { try? FileManager.default.removeItem(at: workspace); try? FileManager.default.removeItem(at: canary) }
        let link = workspace.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: canary.deletingLastPathComponent())
        for cwd in [canary.deletingLastPathComponent().path, workspace.appendingPathComponent("..").path, link.path] {
            do {
                _ = try await host.send(.init(operation: .command, command: "pwd", cwd: cwd, owner: UUID().uuidString))
                XCTFail("workspace外のcwdが受理された")
            } catch { }
        }
        try JSONSerialization.data(withJSONObject: ["path": canary.path, "link": link.appendingPathComponent(canary.lastPathComponent).path]).write(to: workspace.appendingPathComponent("probe.json"))
        let script = """
        import pathlib,json,os
        config=json.load(open("probe.json"))
        paths={"absolute":config["path"],"relative":os.path.relpath(config["path"]),"symlink":config["link"]}
        result={}
        for name,path in paths.items():
            p=pathlib.Path(path)
            try:
                result[name+"_read"]=p.read_text()=="private-canary"
            except OSError:
                result[name+"_read"]=False
        try:
            pathlib.Path(config["path"]).write_text("worker-write")
            result["write"]=True
        except OSError:
            result["write"]=False
        print(json.dumps(result,sort_keys=True))
        """
        try script.write(to: workspace.appendingPathComponent("boundary_probe.py"), atomically: true, encoding: .utf8)
        let result = try await host.send(.init(operation: .command, command: "python3 boundary_probe.py", cwd: workspace.path, owner: UUID().uuidString))
        XCTAssertEqual(result.exitCode, 0, result.output)
        let observation = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Bool])
        XCTAssertEqual(observation.count, 4)
        #if !targetEnvironment(simulator)
        XCTAssertTrue(observation.values.allSatisfy { !$0 }, "Device sandbox did not reject private file access: \(result.output)")
        #endif
        let changed = try String(contentsOf: canary, encoding: .utf8) == "worker-write"
        XCTAssertEqual(observation["write"], changed)
        // Simulator observation is not proof of the device sandbox.
        print("NATIVE_BOUNDARY simulator=true cwd_outside_rejected=true observation=\(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) verified_host_write=\(changed)")
    }

    /// 存在しないコマンドをパイプの上流に置いても、下流が入力を待ち続けないこと(実例: `pdftotext … | sed`)。
    @MainActor
    func testPipelineWithMissingCommandReturns() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        let host = NativeRuntimeHost.shared
        _ = try await host.start { _ in }
        defer { host.stop() }
        let workspace = HyotanBoot.workspaceRoot.appendingPathComponent("native-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        for command in ["pdftotext -layout missing.pdf - | sed -n '1,240p'", "no_such_tool | cat", "pdfinfo missing.pdf 2>/dev/null || true; pdftotext -layout missing.pdf - | sed -n '1,240p'"] {
            let began = Date()
            let owner = UUID().uuidString
            let running = Task { try await host.send(.init(operation: .command, command: command, cwd: workspace.path, owner: owner)) }
            let watchdog = Task { try await Task.sleep(for: .seconds(20)); _ = try? await host.send(.init(operation: .interrupt, owner: owner)) }
            let reply = try await running.value
            watchdog.cancel()
            let seconds = Date().timeIntervalSince(began)
            print("NATIVE_PIPE seconds=\(Int(seconds)) exit=\(reply.exitCode) command=\(command) output=\(reply.output.prefix(200).debugDescription)")
            XCTAssertLessThan(seconds, 15, "パイプが戻らない: \(command)")
        }
        let after = try await host.send(.init(operation: .command, command: "echo alive", cwd: workspace.path, owner: UUID().uuidString))
        XCTAssertEqual(after.output.trimmingCharacters(in: .whitespacesAndNewlines), "alive")
    }

    /// Measure the existing native capability before accepting a virtual replacement.
    @MainActor
    func testNativePythonThreadCreationAndSharedResult() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        XCTAssertTrue(boot.state.isReady)
        let host = NativeRuntimeHost.shared
        _ = try await host.start { _ in }
        defer { host.stop() }
        let workspace = HyotanBoot.workspaceRoot.appendingPathComponent("native-thread-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = """
        import threading
        main_id = threading.get_ident()
        result = []
        def calculate():
            result.append((threading.get_ident() != main_id, sum(range(10000))))
        worker = threading.Thread(target=calculate)
        worker.start()
        worker.join(timeout=5)
        assert not worker.is_alive()
        assert result == [(True, 49995000)], result
        print("NATIVE_PYTHON_THREAD_OK", flush=True)
        """
        try source.write(to: workspace.appendingPathComponent("thread_probe.py"), atomically: true, encoding: .utf8)
        let owner = UUID().uuidString
        let running = Task { try await host.send(.init(operation: .command, command: "python3 thread_probe.py", cwd: workspace.path, owner: owner)) }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            _ = try? await host.send(.init(operation: .interrupt, owner: owner))
        }
        defer { watchdog.cancel() }
        let reply = try await running.value
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.exitCode, 0, reply.output)
        XCTAssertTrue(reply.output.contains("NATIVE_PYTHON_THREAD_OK"), reply.output)
        print("NATIVE_PYTHON_THREAD_BASELINE exit=\(reply.exitCode) assertions_passed=\(reply.exitCode == 0 && reply.output.contains("NATIVE_PYTHON_THREAD_OK"))")
    }

    @MainActor
    func testPythonPackagesCommandsInterruptionAndRestart() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        for name in ["struis_tutor_memory.py", "struis_reply_lint.py"] {
            try XCTSkipUnless(Bundle(for: NativeRuntimeLiveTests.self).url(forResource: name, withExtension: nil) != nil,
                "STRUIS_TEST_DELIVERY_SCRIPTS_DIR is unset; delivered Python scripts are external inputs")
        }
        let boot = HyotanBoot()
        await boot.start()
        XCTAssertTrue(boot.state.isReady)
        let host = NativeRuntimeHost.shared
        let (first, epoch) = try await host.start { _ in }
        defer { host.stop() }
        XCTAssertEqual(first.pid, getpid(), "Codex runs in the app process")
        try recordMemory(first, role: .codex, phase: .start)
        let workspace = HyotanBoot.workspaceRoot.appendingPathComponent("native-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        func run(_ command: String, owner: String = UUID().uuidString) async throws -> NativeRuntimeReply {
            try await host.send(.init(operation: .command, command: command, cwd: workspace.path, owner: owner))
        }
        let math = try await run("""
        python3 -c 'import numpy as n, sympy as s, yaml, pathlib, importlib.util as u, sys; cache=pathlib.Path(s.__cached__).read_bytes(); assert cache[:4]==u.MAGIC_NUMBER and int.from_bytes(cache[4:8],"little")==3; assert sys.flags.optimize==0 and s.expand.__doc__; x=s.symbols("x"); print("NATIVE_MATH", n.dot([1,2],[3,4]), s.expand((x+1)**2), yaml.safe_load("answer: 42")["answer"]); pathlib.Path("日本語.txt").write_text("保存できました", encoding="utf-8")'
        """)
        print("NATIVE_MATH_RESULT exit=\(math.exitCode) output=\(math.output)")
        XCTAssertEqual(math.exitCode, 0, math.output)
        XCTAssertTrue(math.output.contains("NATIVE_MATH 11 x**2 + 2*x + 1 42"), math.output)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("日本語.txt"), encoding: .utf8), "保存できました")
        let execHealth = try await host.commandWorkerHealth()
        XCTAssertEqual(execHealth.pid, math.pid)
        XCTAssertNotEqual(execHealth.pid, first.pid)
        XCTAssertNil(execHealth.error)
        try recordMemory(execHealth, role: .exec, phase: .afterMath)
        let grep = try await run("rg '保存' 日本語.txt")
        XCTAssertEqual(grep.exitCode, 0, grep.output)
        XCTAssertTrue(grep.output.contains("保存できました"))
        let missing = try await run("rg 'not-present' 日本語.txt")
        XCTAssertEqual(missing.exitCode, 1, missing.output)
        let environment = try await run("export STRUIS_COMMAND_ONLY=first; python3 -c 'import os; print(os.getenv(\"STRUIS_COMMAND_ONLY\")); print(os.getcwd()==os.environ[\"WORKSPACE\"])'")
        XCTAssertEqual(environment.output.trimmingCharacters(in: .whitespacesAndNewlines), "first\nTrue")
        let nextEnvironment = try await run("python3 -c 'import os; print(os.getenv(\"STRUIS_COMMAND_ONLY\",\"absent\"))'")
        XCTAssertEqual(nextEnvironment.output.trimmingCharacters(in: .whitespacesAndNewlines), "absent")
        print("NATIVE_ENV first=\(environment.output.debugDescription) next=\(nextEnvironment.output.debugDescription)")
        for filename in ["struis_tutor_memory.py", "struis_reply_lint.py"] {
            let source = try XCTUnwrap(Bundle(for: NativeRuntimeLiveTests.self).url(
                forResource: filename, withExtension: nil
            ), "Missing bundled delivered script: \(filename)")
            try FileManager.default.copyItem(at: source, to: workspace.appendingPathComponent(filename))
        }
        let lint = try await run("printf '%s' '計算結果は $x^2$ です。' | python3 struis_reply_lint.py --stdin")
        XCTAssertEqual(lint.exitCode, 0, lint.output)
        XCTAssertEqual(lint.output.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        let invalid = try await run("printf '%s' '$\\\\unknown{x}$' | python3 struis_reply_lint.py --stdin")
        XCTAssertEqual(invalid.exitCode, 1, invalid.output)
        let memory = try await run("""
        python3 -c 'import pathlib,yaml; p=pathlib.Path("tutor_desk/current"); p.mkdir(parents=True,exist_ok=True); s=dict(learner_id="native-test",thread_id="test-thread",turn_run_id="test-turn",user_message_id="test-message"); (p/"session.yaml").write_text(yaml.safe_dump(s)); pathlib.Path("update.yaml").write_text(yaml.safe_dump(dict(schema_version=1,source=s,future_teaching_change="平方完成の符号を次回確認する"),allow_unicode=True))' && python3 struis_tutor_memory.py submit --file update.yaml
        """)
        XCTAssertEqual(memory.exitCode, 0, memory.output)
        XCTAssertTrue(memory.output.contains("tutor_desk/queue/memory/test-turn-"), memory.output)
        print("NATIVE_DELIVERED_SCRIPTS lint=\(lint.output.trimmingCharacters(in: .whitespacesAndNewlines)) invalid_exit=\(invalid.exitCode) memory_exit=\(memory.exitCode)")
        let owner = UUID().uuidString
        let interruptBegan = Date()
        let waiting = Task { try await run("python3 -c 'import time; print(\"waiting\", flush=True); time.sleep(60)'", owner: owner) }
        try await Task.sleep(for: .seconds(2))
        _ = try await host.send(.init(operation: .interrupt, owner: owner))
        let interrupted = try await waiting.value
        XCTAssertLessThan(Date().timeIntervalSince(interruptBegan), 10, "停止要求後もPythonが終了していない")
        print("NATIVE_INTERRUPT exit=\(interrupted.exitCode) output=\(interrupted.output)")
        XCTAssertNotEqual(interrupted.exitCode, 0)
        let recovered = try await run("python3 -c 'print(7*8)'")
        XCTAssertEqual(recovered.output.trimmingCharacters(in: .whitespacesAndNewlines), "56")
        let bounded = try await run("python3 -c 'print(\"x\"*120000)'")
        XCTAssertTrue(bounded.truncated)
        XCTAssertLessThanOrEqual(bounded.output.utf8.count, 96000)
        print("NATIVE_RESTART_STAGE stopping_host")
        host.stop(ifEpoch: epoch)
        let (second, _) = try await host.start { _ in }
        print("NATIVE_RESTART_STAGE host_started")
        // The in-process server keeps running: a restart is a new connection identity to it.
        XCTAssertNotEqual(first.workerID, second.workerID)
        XCTAssertEqual(first.port, second.port)
        host.stop(ifEpoch: epoch) // A late close must not terminate the replacement worker.
        do {
            _ = try await host.send(.init(operation: .shutdown, workerID: first.workerID))
            XCTFail("旧workerの停止要求が受理された")
        } catch { }
        print("NATIVE_RESTART_STAGE requesting_command")
        let restarted = try await run("python3 -c 'import numpy; print(numpy.sum([20,22]))'")
        XCTAssertEqual(restarted.exitCode, 0, restarted.output)
        XCTAssertEqual(restarted.output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
        print("NATIVE_RESTART old=\(first.workerID) new=\(second.workerID) same_server=\(first.port == second.port) result=42")
        let cOwner = UUID().uuidString
        let cStarted = Date()
        let cWork = Task { try await run("python3 -c 'import hashlib; hashlib.pbkdf2_hmac(\"sha256\",b\"a\",b\"b\",2000000000)'", owner: cOwner) }
        try await Task.sleep(for: .seconds(2))
        print("NATIVE_C_INTERRUPT_STAGE requesting_interrupt")
        _ = try await host.send(.init(operation: .interrupt, owner: cOwner))
        print("NATIVE_C_INTERRUPT_STAGE interrupt_replied")
        do {
            _ = try await cWork.value
            XCTFail("長時間のC処理はワーカー終了により中断される必要がある")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(cStarted), 12)
            print("NATIVE_C_INTERRUPT_STAGE command_failed error=\(String(reflecting: error))")
        }
        // Do not restart Codex here: only the stuck command worker should be retired.
        let afterC = try await host.send(.init(operation: .health))
        print("NATIVE_C_INTERRUPT_STAGE codex_health_replied")
        XCTAssertEqual(afterC.pid, second.pid, "コマンドの強制停止でCodexまで終了した")
        let afterCResult = try await run("python3 -c 'print(6*7)'")
        XCTAssertNotEqual(afterCResult.pid, restarted.pid, "終了したコマンドworkerが交換されていない")
        XCTAssertEqual(afterCResult.exitCode, 0, afterCResult.output)
        XCTAssertEqual(afterCResult.output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
        print("NATIVE_C_INTERRUPT codex_retained=\(afterC.pid == second.pid) worker_replaced=\(afterCResult.pid != restarted.pid) next_output=42")
    }
}

import XCTest
import UIKit
import CryptoKit
import ImageIO
@testable import strius

/// Runs the shipped native worker on Simulator. No command output is mocked.
final class NativeRuntimeLiveTests: XCTestCase {
    private enum MemoryPhase: String { case afterMath = "after_math" }

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

    @MainActor
    func testSimulatorFileBoundaryObservation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        let host = NativeRuntimeHost.shared
        host.prepareForCommands()
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
        host.prepareForCommands()
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
        host.prepareForCommands()
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
        host.prepareForCommands()
        defer { host.stop() }
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
        XCTAssertNotEqual(execHealth.pid, getpid(), "commands run in the Exec extension, not the app")
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
        host.stop()
        host.prepareForCommands()
        print("NATIVE_RESTART_STAGE host_prepared")
        let restarted = try await run("python3 -c 'import numpy; print(numpy.sum([20,22]))'")
        XCTAssertEqual(restarted.exitCode, 0, restarted.output)
        XCTAssertEqual(restarted.output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
        XCTAssertNotEqual(restarted.pid, math.pid, "停止の後は新しいコマンド worker で動く")
        print("NATIVE_RESTART old_pid=\(math.pid) new_pid=\(restarted.pid) result=42")
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
        // Only the stuck command worker is retired; the next command launches a new one.
        let afterCResult = try await run("python3 -c 'print(6*7)'")
        XCTAssertNotEqual(afterCResult.pid, restarted.pid, "終了したコマンドworkerが交換されていない")
        XCTAssertEqual(afterCResult.exitCode, 0, afterCResult.output)
        XCTAssertEqual(afterCResult.output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
        print("NATIVE_C_INTERRUPT worker_replaced=\(afterCResult.pid != restarted.pid) next_output=42")
    }
}

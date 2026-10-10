// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CryptoKit
import Network
@testable import strius

/// Flat, bounded JSON envelope. Rejects duplicate/unknown keys before native calls.
nonisolated private enum VirtualFilesystemValue {
    case string(String), integer(UInt64), boolean(Bool)
}
nonisolated private struct VirtualFilesystemEnvelope {
    let values: [String: VirtualFilesystemValue]
    init(_ data: Data) throws {
        guard (1...65_536).contains(data.count), String(data: data, encoding: .utf8) != nil else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
        let bytes = Array(data); var index = 0; var result: [String: VirtualFilesystemValue] = [:]
        func invalid() -> WorkspaceOperationBroker.Failure { .init(code: EINVAL) }
        func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func take(_ byte: UInt8) throws { whitespace(); guard index < bytes.count, bytes[index] == byte else { throw invalid() }; index += 1 }
        func string() throws -> String {
            whitespace(); let start = index; guard index < bytes.count, bytes[index] == 34 else { throw invalid() }; index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else { throw invalid() }
                    return value
                }
                guard byte >= 32 else { throw invalid() }
            }
            throw invalid()
        }
        try take(123); whitespace()
        if index < bytes.count, bytes[index] == 125 { index += 1 }
        else {
            while true {
                let key = try string(); guard result[key] == nil else { throw invalid() }; try take(58); whitespace()
                guard index < bytes.count else { throw invalid() }
                if bytes[index] == 34 { result[key] = .string(try string()) }
                else {
                    let start = index
                    while index < bytes.count, bytes[index] != 44, bytes[index] != 125 { index += 1 }
                    let token = String(decoding: bytes[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if token == "true" { result[key] = .boolean(true) }
                    else if token == "false" { result[key] = .boolean(false) }
                    else {
                        guard !token.isEmpty, token.utf8.allSatisfy({ (48...57).contains($0) }), (token.count == 1 || token.first != "0"), let number = UInt64(token) else { throw invalid() }
                        result[key] = .integer(number)
                    }
                }
                whitespace(); guard index < bytes.count else { throw invalid() }
                if bytes[index] == 125 { index += 1; break }
                try take(44)
            }
        }
        whitespace(); guard index == bytes.count else { throw invalid() }; values = result
    }
    func string(_ key: String) throws -> String { guard case .some(.string(let value)) = values[key] else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }; return value }
    func integer(_ key: String) throws -> UInt64 { guard case .some(.integer(let value)) = values[key] else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }; return value }
    func decimal(_ key: String) throws -> UInt64 {
        let value = try string(key)
        guard (1...20).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(value) else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
        return number
    }
}

/// Global test-only ID allocator: a closed/revoked ID never aliases a new grant.
nonisolated private final class VirtualFilesystemIDs: @unchecked Sendable {
    static let shared = VirtualFilesystemIDs()
    private let lock = NSLock(); private var next: UInt64 = 1
    func issue() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard next < UInt64.max else { throw WorkspaceOperationBroker.Failure(code: ENOSPC) }
        defer { next += 1 }; return String(next)
    }
}

/// An immutable trusted broker per origin. No guest-selected root/scope/pointer.
nonisolated final class VirtualFilesystemDispatcher: @unchecked Sendable {
    private let broker: WorkspaceOperationBroker
    private let lock = NSLock()
    private var handles: [String: WorkspaceOperationBroker.FileHandle] = [:]
    private var stopped = false
    private var operations = 0
    init(broker: WorkspaceOperationBroker) { self.broker = broker }
    var operationCount: Int { lock.lock(); defer { lock.unlock() }; return operations }
    func registerTrustedForeignHandle(_ handle: WorkspaceOperationBroker.FileHandle) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let id = try VirtualFilesystemIDs.shared.issue(); handles[id] = handle; return id
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true
        try? broker.revoke(); handles.removeAll(); try? broker.destroy()
    }
    private func handle(_ request: VirtualFilesystemEnvelope) throws -> WorkspaceOperationBroker.FileHandle {
        let id = try request.string("handle"); _ = try request.decimal("handle")
        guard let handle = handles[id] else { throw WorkspaceOperationBroker.Failure(code: EACCES) }; return handle
    }
    private func metadata(_ value: WorkspaceOperationBroker.Metadata) -> [String: Any] {
        ["directory": value.isDirectory, "bytes": value.bytes,
         "created": value.createdAtMilliseconds.map { $0 as Any } ?? NSNull(),
         "modified": value.modifiedAtMilliseconds.map { $0 as Any } ?? NSNull()]
    }
    private func errnoName(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "EACCES"
        case ENOENT: return "ENOENT"
        case EEXIST: return "EEXIST"
        case EINVAL: return "EINVAL"
        case EFBIG: return "EFBIG"
        case ENOSPC: return "ENOSPC"
        case EMFILE: return "EMFILE"
        case ENOTSUP: return "ENOTSUP"
        case ENOTDIR: return "ENOTDIR"
        case EISDIR: return "EISDIR"
        case ENOTEMPTY: return "ENOTEMPTY"
        default: return "EIO"
        }
    }
    func execute(_ data: Data) -> Data {
        lock.lock(); defer { lock.unlock() }
        var sequence: UInt64 = 0
        do {
            let request = try VirtualFilesystemEnvelope(data); sequence = try request.integer("sequence")
            guard (1..<2_147_483_648).contains(sequence), !stopped else { throw WorkspaceOperationBroker.Failure(code: stopped ? EACCES : EINVAL) }
            let operation = try request.string("operation")
            let fields: [String: Set<String>] = ["descriptorPolicy": [], "open": ["path", "flags"], "metadata": ["path"], "list": ["path"], "mkdir": ["path"], "remove": ["path", "recursive"], "read": ["handle", "offset", "length"], "write": ["handle", "offset", "data"], "truncate": ["handle", "length"], "stat": ["handle"], "close": ["handle"], "rename": ["source", "destination"]]
            guard let expected = fields[operation], Set(request.values.keys) == expected.union(["sequence", "operation"]) else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
            operations += 1
            var response: [String: Any] = ["sequence": sequence]
            switch operation {
            case "descriptorPolicy":
                let policy = try broker.descriptorPolicy()
                response["policy"] = ["readExtent": String(policy.readExtent), "writeExtent": String(policy.writeExtent), "configured": policy.configured]
            case "open":
                let flags = try request.integer("flags")
                guard (1..<64).contains(flags), handles.count < 64 else { throw WorkspaceOperationBroker.Failure(code: handles.count >= 64 ? EMFILE : EINVAL) }
                let native = try broker.open(request.string("path"), options: .init(rawValue: UInt32(flags)))
                do { let id = try VirtualFilesystemIDs.shared.issue(); handles[id] = native; response["handle"] = id }
                catch { try? broker.close(native); throw error }
            case "rename": try broker.rename(request.string("source"), to: request.string("destination"))
            case "metadata": response["metadata"] = metadata(try broker.metadata(request.string("path")))
            case "stat": response["metadata"] = metadata(try broker.stat(handle(request)))
            case "close": let native = try handle(request); try broker.close(native); handles.removeValue(forKey: try request.string("handle"))
            case "truncate": try broker.truncate(handle(request), length: request.decimal("length"))
            case "read":
                let count = try request.integer("length"); guard count <= 16_384 else { throw WorkspaceOperationBroker.Failure(code: EFBIG) }
                response["data"] = try broker.read(handle(request), offset: request.decimal("offset"), count: Int(count)).base64EncodedString()
            case "write":
                let encoded = try request.string("data")
                guard encoded.utf8.count <= 21_848, let bytes = Data(base64Encoded: encoded), bytes.count <= 16_384 else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
                response["written"] = try broker.write(handle(request), offset: request.decimal("offset"), data: bytes)
            case "list": response["names"] = try broker.list(request.string("path"))
            case "mkdir": try broker.mkdir(request.string("path"))
            case "remove":
                guard case .some(.boolean(false)) = request.values["recursive"] else { throw WorkspaceOperationBroker.Failure(code: ENOTSUP) }
                try broker.remove(request.string("path"))
            default: throw WorkspaceOperationBroker.Failure(code: ENOTSUP)
            }
            let result = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            guard result.count <= 65_536 else { throw WorkspaceOperationBroker.Failure(code: EFBIG) }; return result
        } catch {
            let failure = (error as? WorkspaceOperationBroker.Failure) ?? .init(code: EINVAL)
            return (try? JSONSerialization.data(withJSONObject: ["sequence": sequence, "errno": errnoName(failure.code), "message": failure.localizedDescription], options: [.sortedKeys])) ?? Data()
        }
    }
}

nonisolated struct VirtualFilesystemAssets: Sendable {
    let files: [String: Data]
    init(bundle: Bundle) throws {
        guard let root = bundle.url(forResource: "VirtualPythonTestAssets", withExtension: nil),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any],
              manifest["format_version"] as? Int == 1, manifest["pyodide_version"] as? String == "314.0.7", manifest["python_version"] as? String == "3.14.2",
              let entries = manifest["files"] as? [String: [String: Any]] else { throw NSError(domain: "VirtualFilesystemAssets", code: 1) }
        let inventoryText = try String(contentsOf: root.appendingPathComponent("resources.js"), encoding: .utf8)
        guard let marker = inventoryText.range(of: "export const resources = "),
              let inventory = try JSONSerialization.jsonObject(with: Data(inventoryText[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).dropLast().utf8)) as? [String: String], inventory.count == 9 else { throw NSError(domain: "VirtualFilesystemAssets", code: 2) }
        let names = ["main.js", "worker.js", "filesystem.js", "resources.js", "stdio.js", "hyotan_runner.py"] + inventory.keys.map { "py/" + $0 }
        var loaded: [String: Data] = [:]
        for name in names {
            guard !name.contains(".."), let entry = entries[name], let expected = entry["sha256"] as? String, let count = entry["bytes"] as? Int, (1...67_108_864).contains(count) else { throw NSError(domain: "VirtualFilesystemAssets", code: 3) }
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == count, digest == expected, !name.hasPrefix("py/") || digest == inventory[String(name.dropFirst(3))] else { throw NSError(domain: "VirtualFilesystemAssets", code: 4) }
            loaded[name] = data
        }
        files = loaded
    }
}

/// Bounded HTTP/1.1 origin, fixed assets and immutable dispatcher only.
nonisolated final class VirtualFilesystemOrigin: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "virtual-python.filesystem-origin")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var accepted = 0
    private var pendingStart: CheckedContinuation<UInt16, Error>?
    private let assets: [String: Data]
    private let dispatcher: VirtualFilesystemDispatcher
    let nonce: String
    private let provider: (@Sendable (Data) async -> Data)?
    convenience init(assets: VirtualFilesystemAssets, dispatcher: VirtualFilesystemDispatcher, python: String, nonce: String, commandBootstrap: String? = nil, gitHistoryAssets: VirtualGitHistoryAssets? = nil, provider: (@Sendable (Data) async -> Data)? = nil) throws {
        try self.init(fixedAssets: assets.files, dispatcher: dispatcher, python: python, nonce: nonce, commandBootstrap: commandBootstrap, gitHistoryAssets: gitHistoryAssets, provider: provider)
    }
    /// Trusted callers supply an already validated fixed map; never a host path.
    init(fixedAssets: [String: Data], dispatcher: VirtualFilesystemDispatcher, python: String, nonce: String, commandBootstrap: String? = nil, gitHistoryAssets: VirtualGitHistoryAssets? = nil, provider: (@Sendable (Data) async -> Data)? = nil) throws {
        self.dispatcher = dispatcher; self.nonce = nonce; self.provider = provider
        let code = String(decoding: try JSONSerialization.data(withJSONObject: python, options: [.fragmentsAllowed]), as: UTF8.self)
        let token = String(decoding: try JSONSerialization.data(withJSONObject: nonce, options: [.fragmentsAllowed]), as: UTF8.self)
        let bootstrap = commandBootstrap ?? """
        import {runVirtualPython} from './main.js';
        let heartbeat=0;const pulse=setInterval(()=>heartbeat++,5);
        const workers=new Set(), controllers=new Set(), NativeWorker=globalThis.Worker, NativeAbort=globalThis.AbortController;
        globalThis.Worker=class extends NativeWorker { constructor(...args){super(...args);workers.add(this);} terminate(){workers.delete(this);super.terminate();} };
        globalThis.AbortController=class extends NativeAbort { constructor(...args){super(...args);controllers.add(this);} };
        globalThis.filesystemTeardown=()=>{clearInterval(pulse);for(const c of controllers)c.abort();controllers.clear();for(const w of workers)w.terminate();workers.clear();};
        try { const result=await runVirtualPython(\(code)); webkit.messageHandlers.filesystemResult.postMessage({nonce:\(token),mainHeartbeat:heartbeat,...result}); }
        catch(error) { webkit.messageHandlers.filesystemResult.postMessage({nonce:\(token),success:false,error:String(error)}); }
        finally { globalThis.filesystemTeardown(); }
        """
        var files = fixedAssets; if let gitHistoryAssets { for (name, data) in gitHistoryAssets.files { guard files[name] == nil, name.hasPrefix("git/") else { throw NSError(domain: "VirtualFilesystemOrigin", code: 5) }; files[name] = data } }; files["test.js"] = Data(bootstrap.utf8)
        files["index.html"] = Data("<!doctype html><meta charset=utf-8><script type=module src=test.js></script>".utf8)
        self.assets = files
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    private func resolve(_ result: Result<UInt16, Error>) {
        lock.lock(); let continuation = pendingStart; pendingStart = nil; lock.unlock(); continuation?.resume(with: result)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); pendingStart = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: if let port = self.listener.port { self.resolve(.success(port.rawValue)) } else { self.resolve(.failure(URLError(.cannotConnectToHost))) }
                case .failed(let error), .waiting(let error): self.resolve(.failure(error))
                case .cancelled: self.resolve(.failure(URLError(.cancelled)))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in guard let self else { connection.cancel(); return }; self.accept(connection) }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.resolve(.failure(URLError(.timedOut))) }
            listener.start(queue: queue)
        }
    }
    func stop() {
        lock.lock(); stopped = true; let active = Array(connections.values); connections.removeAll(); lock.unlock()
        resolve(.failure(URLError(.cancelled))); listener.cancel(); active.forEach { $0.cancel() }; dispatcher.stop()
    }
    private func isActive(_ connection: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }; return !stopped && connections[ObjectIdentifier(connection)] != nil
    }
    private func finish(_ connection: NWConnection) {
        lock.lock(); connections.removeValue(forKey: ObjectIdentifier(connection)); lock.unlock(); connection.cancel()
    }
    private func accept(_ connection: NWConnection) {
        lock.lock(); guard !stopped, accepted < 1024, connections.count < 16 else { lock.unlock(); connection.cancel(); return }
        accepted += 1; connections[ObjectIdentifier(connection)] = connection; lock.unlock()
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in guard let self, let connection else { return }; self.finish(connection) }
        receive(connection, buffer: Data())
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            guard !stopped, error == nil else { self.finish(connection); return }
            var bytes = buffer; if let data { bytes.append(data) }
            guard bytes.count <= 8192 + 65_536 else { self.finish(connection); return }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                guard bytes.count <= 8192, !complete else { self.finish(connection); return }; self.receive(connection, buffer: bytes); return
            }
            guard end.upperBound <= 8192, let text = String(data: bytes[..<end.lowerBound], encoding: .ascii), let port = self.listener.port else { self.finish(connection); return }
            let lines = text.components(separatedBy: "\r\n"); let request = (lines.first ?? "").split(separator: " ")
            guard request.count == 3, request[2] == "HTTP/1.1" else { self.finish(connection); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { self.finish(connection); return }
                let key = String(pair[0]).lowercased(), value = pair[1].trimmingCharacters(in: .whitespaces)
                guard headers[key] == nil else { self.finish(connection); return }; headers[key] = value
            }
            guard headers["host"] == "127.0.0.1:\(port.rawValue)", headers["transfer-encoding"] == nil else { self.finish(connection); return }
            let prefix = "/\(self.nonce)/", path = String(request[1])
            guard path.hasPrefix(prefix) else { self.finish(connection); return }
            let name = String(path.dropFirst(prefix.count)), body = Data(bytes[end.upperBound...])
            if request[0] == "GET" {
                guard body.isEmpty, headers["content-length"] == nil || headers["content-length"] == "0", let asset = self.assets[name] else { self.finish(connection); return }
                let mime = name.hasSuffix(".js") || name.hasSuffix(".mjs") ? "application/javascript" : name.hasSuffix(".html") ? "text/html; charset=utf-8" : (name.hasSuffix(".wasm") || name.hasSuffix(".so")) ? "application/wasm" : "application/octet-stream"
                self.respond(connection, data: asset, mime: mime)
            } else if request[0] == "POST" {
                guard (["broker", "operation"].contains(name) || (name == "provider" && self.provider != nil)), headers["origin"] == "http://127.0.0.1:\(port.rawValue)", headers["content-type"] == "application/json",
                      let lengthText = headers["content-length"], lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText), (1...65_536).contains(length), body.count <= length else { self.finish(connection); return }
                if body.count < length { guard !complete else { self.finish(connection); return }; self.receive(connection, buffer: bytes); return }
                if name == "provider", let provider = self.provider {
                    Task { [weak self] in
                        guard let self, self.isActive(connection) else { return }
                        let reply = await provider(body)
                        let active = self.isActive(connection)
                        if active { self.respond(connection, data: reply, mime: "application/json") }
                    }
                } else { self.respond(connection, data: self.dispatcher.execute(body), mime: "application/json") }
            } else { self.finish(connection) }
        }
    }
    private func respond(_ connection: NWConnection, data: Data, mime: String) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-eval' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        var response = Data(headers.utf8); response.append(data)
        connection.send(content: response, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
    }
}

#if DEBUG && targetEnvironment(simulator)
nonisolated struct VirtualPythonProviderRequest: Sendable {
    let operation: String
    var stdout = Data(), stderr = Data()
    var capacity = 0
    var exitCode: Int32 = 0
    init(_ data: Data) throws {
        let request = try VirtualFilesystemEnvelope(data)
        operation = try request.string("operation")
        let fields: Set<String>
        switch operation {
        case "exchange": fields = ["operation", "stdout", "stderr", "capacity"]
        case "finish": fields = ["operation", "exitCode"]
        case "cancel": fields = ["operation"]
        default: throw WorkspaceOperationBroker.Failure(code: EINVAL)
        }
        guard Set(request.values.keys) == fields else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
        if operation == "exchange" {
            func bytes(_ key: String) throws -> Data {
                let encoded = try request.string(key)
                guard encoded.utf8.count <= 21848, let decoded = Data(base64Encoded: encoded), decoded.count <= 16384,
                      decoded.base64EncodedString() == encoded else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
                return decoded
            }
            stdout = try bytes("stdout"); stderr = try bytes("stderr")
            let value = try request.integer("capacity")
            guard value <= 16384 else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }; capacity = Int(value)
        } else if operation == "finish" {
            let value = try request.string("exitCode")
            guard value.utf8.count <= 11, let code = Int32(value), String(code) == value else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
            exitCode = code
        }
    }
}
#endif

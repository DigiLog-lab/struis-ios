// SPDX-License-Identifier: Apache-2.0
import XCTest
import Foundation
import Darwin
import UIKit
import WebKit
@testable import strius

@MainActor
final class VirtualFilesystemReporter: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let url: URL
    let nonce: String
    let completion: XCTestExpectation
    var report: [String: Any]?
    private var finished = false
    init(url: URL, nonce: String, completion: XCTestExpectation) { self.url = url; self.nonce = nonce; self.completion = completion }
    private func finish(_ report: [String: Any]) { guard !finished else { return }; finished = true; self.report = report; completion.fulfill() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "http", message.frameInfo.securityOrigin.host == "127.0.0.1", message.frameInfo.securityOrigin.port == (url.port ?? -1),
              let value = message.body as? [String: Any], value["nonce"] as? String == nonce else { finish(["success": false, "error": "invalid filesystem report"]); return }
        finish(value)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url == url ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(["success": false, "error": "WK navigation failed"]) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(["success": false, "error": "WK provisional navigation failed"]) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(["success": false, "error": "WK content process terminated"]) }
}

/// One bounded evaluation; a dead WebContent process cannot strand teardown.
@MainActor
private final class VirtualFilesystemEvaluation {
    private var continuation: CheckedContinuation<Bool, Never>?
    private func finish(_ value: Bool) { let pending = continuation; continuation = nil; pending?.resume(returning: value) }
    func run(_ script: String, in webView: WKWebView, timeout: UInt64 = 750_000_000) async -> Bool {
        await withCheckedContinuation { pending in
            continuation = pending
            webView.evaluateJavaScript(script) { [weak self] value, error in
                let executed = error == nil && (value as? Bool == true)
                Task { @MainActor in self?.finish(executed) }
            }
            Task { @MainActor [weak self] in try? await Task.sleep(nanoseconds: timeout); self?.finish(false) }
        }
    }
}

@MainActor
final class VirtualFilesystemView {
    let webView: WKWebView
    let reporter: VirtualFilesystemReporter
    private let configuration: WKWebViewConfiguration
    private let window: UIWindow
    private var detached = false
    init(url: URL, nonce: String, completion: XCTestExpectation) {
        let reporter = VirtualFilesystemReporter(url: url, nonce: nonce, completion: completion)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(reporter, name: "filesystemResult")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 240) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240)) }
        self.reporter = reporter; self.configuration = configuration; self.webView = webView; self.window = window
        webView.navigationDelegate = reporter
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(webView); window.isHidden = false
        webView.load(URLRequest(url: url))
    }
    func teardown() async {
        _ = await VirtualFilesystemEvaluation().run("globalThis.filesystemTeardown?.(); true", in: webView)
        detach()
    }
    func detach() {
        guard !detached else { return }; detached = true
        webView.stopLoading(); configuration.userContentController.removeScriptMessageHandler(forName: "filesystemResult"); webView.navigationDelegate = nil
        webView.loadHTMLString("<!doctype html><title>closed</title>", baseURL: nil); webView.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
    }

}

/// Actual Pyodide packages and filesystem operations on WK; no native Python switch.
final class VirtualPythonFilesystemTests: XCTestCase {
    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    func testRealWKPythonMathFilesDenialsRevocationAndFreshGrant() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1" && ProcessInfo.processInfo.environment["STRUIS_VIRTUAL_PYTHON_LIVE"] == "1", "dedicated RuntimeTests virtual Python test is opt-in")
        try XCTSkipUnless(Bundle(for: Self.self).url(forResource: "VirtualPythonTestAssets", withExtension: nil) != nil,
            "VirtualPythonTestAssets are absent; run prepare-virtual-python-test-assets.py before building")
        let assets = try VirtualFilesystemAssets(bundle: Bundle(for: Self.self))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("virtual-python-" + UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace"), canary = base.appendingPathComponent("private/canary")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let privateBytes = Data("synthetic-private-canary".utf8); try privateBytes.write(to: canary)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"), withDestinationURL: canary)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("ancestor"), withDestinationURL: canary.deletingLastPathComponent())
        guard Darwin.link(canary.path, workspace.appendingPathComponent("hard").path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let fd = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; defer { Darwin.close(fd) }
        let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-wk-test", generation: 101, access: .readWrite)
        let other = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-wk-foreign", generation: 102, access: .readWrite)
        defer { try? broker.destroy(); try? other.destroy() }
        let foreign = try other.open("foreign", options: [.read, .write, .create])
        let dispatcher = VirtualFilesystemDispatcher(broker: broker)
        let foreignID = try dispatcher.registerTrustedForeignHandle(foreign)
        // JSON escapes such as \/ are not Python string escapes. Decode the
        // exact JSON bytes with JSON instead of inserting them as a Python literal.
        let canaryJSON = try JSONSerialization.data(withJSONObject: canary.path, options: [.fragmentsAllowed])
        let quotedCanary = "json.loads(bytes.fromhex('\(canaryJSON.map { String(format: "%02x", $0) }.joined())').decode('utf-8'))"
        let python = Self.python.replacingOccurrences(of: "FOREIGN_HANDLE", with: foreignID).replacingOccurrences(of: "PRIVATE_CANARY", with: quotedCanary)
        let nonce = UUID().uuidString.lowercased(), origin = try VirtualFilesystemOrigin(assets: assets, dispatcher: dispatcher, python: python, nonce: nonce)
        defer { origin.stop() }
        let port = try await origin.start(), url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(nonce)/index.html"))
        let completed = expectation(description: "actual WK Python filesystem workload")
        let view = VirtualFilesystemView(url: url, nonce: nonce, completion: completed)
        defer { view.detach() }
        await fulfillment(of: [completed], timeout: 28)
        let report = view.reporter.report
        // Teardown of the real Worker is awaited before any assertion can throw.
        await view.teardown()
        let value = try XCTUnwrap(report, "WK Python result missing; timeout/unsupported is failure")
        XCTAssertEqual(value["success"] as? Bool, true, "Actual WK Python failed: \(value["error"] ?? "unknown")")
        guard value["success"] as? Bool == true else { return }
        let details = try XCTUnwrap((value["value"] as? String)?.data(using: .utf8)).flatMapJSON()
        XCTAssertEqual(details["solve"] as? [Double], [1.6, 1.8]); XCTAssertEqual(details["integral"] as? String, "9")
        XCTAssertEqual(details["schema_denials"] as? [String], Array(repeating: "EINVAL", count: 3))
        XCTAssertEqual(details["foreign"] as? String, "EACCES"); XCTAssertEqual(details["closed"] as? String, "EACCES")
        XCTAssertEqual(details["bridge_denials"] as? [String], Array(repeating: "EACCES", count: 5))
        let messages = try XCTUnwrap(details["denial_messages"] as? [String]); XCTAssertEqual(messages.count, 5)
        XCTAssertTrue(messages.allSatisfy { $0.contains("active workspace") && !$0.contains(canary.path) })
        XCTAssertEqual((value["browser"] as? [String: Any])?["isolated"] as? Bool, true)
        XCTAssertGreaterThan((value["mainHeartbeat"] as? Int) ?? 0, 2)
        let observed = try XCTUnwrap(value["deniedOperations"] as? [[String: Any]])
        XCTAssertTrue(observed.contains { item in
            guard let operation = item["operation"] as? String, let message = item["message"] as? String else { return false }
            return (operation == "metadata" || operation == "open") && message.contains("active workspace")
        })
        XCTAssertGreaterThan(dispatcher.operationCount, 30)
        let binary = try broker.open("日本語.bin", options: .read); defer { try? broker.close(binary) }
        XCTAssertEqual(try broker.stat(binary).bytes, 8193); XCTAssertEqual(try broker.read(binary, offset: 123, count: 7), Data("changed".utf8))
        let math = try read("math.json", broker: broker).flatMapJSON()
        XCTAssertEqual(math["solve"] as? [Double], [1.6, 1.8]); XCTAssertEqual(math["integral"] as? String, "9")
        XCTAssertTrue(String(decoding: try read("計算.yaml", broker: broker), as: UTF8.self).contains("integral"))
        XCTAssertTrue(try read("配列.npy", broker: broker).starts(with: Data([0x93]) + Data("NUMPY".utf8)))
        XCTAssertTrue(String(decoding: try read("数式.txt", broker: broker), as: UTF8.self).contains("x**4"))
        XCTAssertEqual(try read("published.txt", broker: broker), Data("new-content".utf8))
        XCTAssertEqual(try Data(contentsOf: canary), privateBytes)
        try other.close(foreign)
        try broker.revoke()
        // A new page at the OLD origin must remain denied; it cannot be rebound.
        let oldCompleted = expectation(description: "revoked origin rejects new Worker")
        let oldView = VirtualFilesystemView(url: url, nonce: nonce, completion: oldCompleted)
        defer { oldView.detach() }
        await fulfillment(of: [oldCompleted], timeout: 28)
        let denied = oldView.reporter.report; await oldView.teardown()
        XCTAssertEqual(denied?["success"] as? Bool, false)
        XCTAssertTrue((denied?["error"] as? String)?.contains("active workspace") == true)
        let revokedOperations = try XCTUnwrap(denied?["deniedOperations"] as? [[String: Any]])
        XCTAssertTrue(revokedOperations.contains { item in item["operation"] as? String == "metadata" && item["errno"] as? String == "EACCES" && ((item["message"] as? String)?.contains("active workspace") ?? false) })
        let fresh = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-wk-next", generation: 103, access: .readWrite)
        defer { try? fresh.destroy() }
        let freshDispatcher = VirtualFilesystemDispatcher(broker: fresh)
        let nextNonce = UUID().uuidString.lowercased()
        let staleJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["operation": "read", "handle": foreignID, "offset": "0", "length": 1], options: [.sortedKeys]), as: UTF8.self)
        let staleLiteral = String(decoding: try JSONSerialization.data(withJSONObject: staleJSON, options: [.fragmentsAllowed]), as: UTF8.self)
        let freshCode = "from pathlib import Path; import js; Path('/workspace/next.txt').write_text('fresh'); assert js.virtualFSRequest(js.JSON.parse(\(staleLiteral))).errno == 'EACCES'; 'fresh'"
        let nextOrigin = try VirtualFilesystemOrigin(assets: assets, dispatcher: freshDispatcher, python: freshCode, nonce: nextNonce)
        defer { nextOrigin.stop() }
        let nextPort = try await nextOrigin.start(), nextURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(nextPort)/\(nextNonce)/index.html"))
        let nextCompleted = expectation(description: "fresh WK Python grant")
        let nextView = VirtualFilesystemView(url: nextURL, nonce: nextNonce, completion: nextCompleted)
        defer { nextView.detach() }
        await fulfillment(of: [nextCompleted], timeout: 28)
        let nextReport = nextView.reporter.report; await nextView.teardown()
        XCTAssertEqual(nextReport?["success"] as? Bool, true, "Fresh actual Python failed: \(nextReport?["error"] ?? "unknown")")
        XCTAssertEqual(String(decoding: try read("next.txt", broker: fresh), as: UTF8.self), "fresh")
        XCTAssertEqual(try Data(contentsOf: canary), privateBytes)
        let canaryUnchanged = try Data(contentsOf: canary) == privateBytes
        let revokedDenied = denied?["success"] as? Bool == false
        let pythonSucceeded = value["success"] as? Bool == true
        let freshSucceeded = nextReport?["success"] as? Bool == true
        let attachment = XCTAttachment(string: "Actual WK Python \(details); broker operation requests \(dispatcher.operationCount); old grant denied=\(revokedDenied); fresh actual worker result=\(freshSucceeded); canary unchanged=\(canaryUnchanged)")
        attachment.name = "VirtualPythonFilesystem synthetic evidence"; attachment.lifetime = .keepAlways; add(attachment)
        print("VIRTUAL_PYTHON_FILESYSTEM python_success=\(pythonSucceeded) operation_requests=\(dispatcher.operationCount) numpy=\(details["numpy"] ?? "unknown") sympy=\(details["sympy"] ?? "unknown") yaml=\(details["yaml"] ?? "unknown") revoked_origin_denied=\(revokedDenied) fresh_python_success=\(freshSucceeded) canary_unchanged=\(canaryUnchanged)")
    }

    @MainActor
    func testTypedDispatcherRejectsDuplicateAndAuthorityEnvelopesBeforeNativeMutation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1" && ProcessInfo.processInfo.environment["STRUIS_VIRTUAL_PYTHON_LIVE"] == "1", "dedicated RuntimeTests virtual Python test is opt-in")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("virtual-python-envelope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; defer { Darwin.close(fd) }
        let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-wk-envelope", generation: 301, access: .readWrite)
        let dispatcher = VirtualFilesystemDispatcher(broker: broker); defer { dispatcher.stop() }
        let invalid = [
            #"{"sequence":1,"sequence":2,"operation":"mkdir","path":"forbidden"}"#,
            #"{"sequence":1,"operation":"mkdir","path":"forbidden","root":"/"}"#,
            #"{"sequence":1,"operation":"open","path":"forbidden","flags":true}"#,
            #"{"sequence":1,"operation":"read","handle":1,"offset":"0","length":1}"#,
            #"{"sequence":1,"operation":"mkdir","path":"forbidden","generation":"new"}"#
        ]
        for body in invalid {
            let failure = try dispatcher.execute(Data(body.utf8)).flatMapJSON()
            XCTAssertEqual(failure["errno"] as? String, "EINVAL")
        }
        XCTAssertEqual(try broker.list(), [])
        let valid = try dispatcher.execute(Data(#"{"sequence":1,"operation":"mkdir","path":"資料"}"#.utf8)).flatMapJSON()
        XCTAssertNil(valid["errno"]); XCTAssertEqual(try broker.list(), ["資料"])
    }

    @MainActor
    func testUnhandledPythonDenialReportsPermittedAlternative() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1" && ProcessInfo.processInfo.environment["STRUIS_VIRTUAL_PYTHON_LIVE"] == "1", "dedicated RuntimeTests virtual Python test is opt-in")
        try XCTSkipUnless(Bundle(for: Self.self).url(forResource: "VirtualPythonTestAssets", withExtension: nil) != nil,
            "VirtualPythonTestAssets are absent; run prepare-virtual-python-test-assets.py before building")
        let assets = try VirtualFilesystemAssets(bundle: Bundle(for: Self.self))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("virtual-python-denial-" + UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace"), canary = base.appendingPathComponent("private-canary")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let privateBytes = Data("synthetic-private-canary".utf8); try privateBytes.write(to: canary)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"), withDestinationURL: canary)
        let fd = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; defer { Darwin.close(fd) }
        let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-wk-denial", generation: 201, access: .readWrite)
        defer { try? broker.destroy() }
        let dispatcher = VirtualFilesystemDispatcher(broker: broker), nonce = UUID().uuidString.lowercased()
        let origin = try VirtualFilesystemOrigin(assets: assets, dispatcher: dispatcher, python: "from pathlib import Path; Path('/workspace/escape').read_bytes()", nonce: nonce)
        defer { origin.stop() }
        let port = try await origin.start(), url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(nonce)/index.html"))
        let completed = expectation(description: "unhandled actual Python PermissionError")
        let view = VirtualFilesystemView(url: url, nonce: nonce, completion: completed); defer { view.detach() }
        await fulfillment(of: [completed], timeout: 28)
        let report = view.reporter.report; await view.teardown()
        let result = try XCTUnwrap(report, "missing actual denied Python result")
        XCTAssertEqual(result["success"] as? Bool, false)
        let message = try XCTUnwrap(result["error"] as? String)
        XCTAssertTrue(message.contains("PermissionError")); XCTAssertTrue(message.contains("active workspace")); XCTAssertFalse(message.contains(canary.path))
        let denied = try XCTUnwrap(result["deniedOperations"] as? [[String: Any]])
        XCTAssertTrue(denied.contains { item in
            guard let operation = item["operation"] as? String, let message = item["message"] as? String else { return false }
            return (operation == "metadata" || operation == "open") && message.contains("active workspace")
        })
        XCTAssertEqual(try Data(contentsOf: canary), privateBytes)
        let canaryUnchanged = try Data(contentsOf: canary) == privateBytes
        print("VIRTUAL_PYTHON_FILESYSTEM_UNHANDLED python_success=\(result["success"] as? Bool == true) permission_error=\(message.contains("PermissionError")) permitted_alternative=\(message.contains("active workspace")) canary_unchanged=\(canaryUnchanged)")
    }

    @MainActor
    private func read(_ path: String, broker: WorkspaceOperationBroker) throws -> Data {
        let handle = try broker.open(path, options: .read); defer { try? broker.close(handle) }
        return try broker.read(handle, offset: 0, count: 16_384)
    }
    private static let python = #"""
import os,json,errno
from pathlib import Path
import numpy as np,sympy as sp,yaml,js
p=Path('/workspace/日本語.bin')
with p.open('w+b') as f:
 f.write(bytes(range(256))*257);f.seek(123);f.write(b'changed');f.seek(123);assert f.read(7)==b'changed';f.truncate(8193);assert os.fstat(f.fileno()).st_size==8193
Path('/workspace/資料').mkdir();assert os.listdir('/workspace/資料')==[]
q=Path('/workspace/資料/erase');q.write_bytes(b'delete');q.unlink();Path('/workspace/資料').rmdir()
x=sp.Symbol('x')
r={'solve':np.linalg.solve([[2.,1.],[1.,3.]],[5.,7.]).tolist(),'integral':str(sp.integrate(x**2,(x,0,3)))}
Path('/workspace/math.json').write_text(json.dumps(r))
Path('/workspace/計算.yaml').write_text(yaml.safe_dump(r,allow_unicode=True));assert yaml.safe_load(Path('/workspace/計算.yaml').read_text())==r
with open('/workspace/配列.npy','wb') as f:np.save(f,np.arange(100,dtype=np.int64))
with open('/workspace/配列.npy','rb') as f:assert np.array_equal(np.load(f),np.arange(100))
Path('/workspace/数式.txt').write_text(str(sp.expand((x+1)**4)))
for path in ['/private-canary','/workspace/../private/canary','/workspace/escape','/workspace/hard','/workspace/ancestor/canary']:
 try:Path(path).read_bytes();raise AssertionError('escape allowed')
 except (PermissionError,FileNotFoundError):pass
assert os.path.isabs(PRIVATE_CANARY), 'private canary fixture must preserve its absolute path'
answers=[js.virtualFSRequest(js.JSON.parse(json.dumps({'operation':'open','path':path,'flags':1}))) for path in [PRIVATE_CANARY,'../private/canary','escape','hard','ancestor/canary']]
r['bridge_denials']=[str(a.errno) for a in answers];r['denial_messages']=[str(a.message) for a in answers]
assert r['bridge_denials']==['EACCES']*5, json.dumps(r['bridge_denials'])
assert all('active workspace' in text for text in r['denial_messages']), json.dumps(r['denial_messages'])
r['schema_denials']=[str(js.virtualFSRequest(js.JSON.parse(json.dumps(v))).errno) for v in [{'operation':'metadata','path':'','owner':'guest'},{'operation':'open','path':'forbidden','flags':True},{'operation':'read','handle':1,'offset':'0','length':1}]]
r['foreign']=str(js.virtualFSRequest(js.JSON.parse('{"operation":"read","handle":"FOREIGN_HANDLE","offset":"0","length":1}')).errno)
h=js.virtualFSRequest(js.JSON.parse('{"operation":"open","path":"日本語.bin","flags":1}')).handle
js.virtualFSRequest(js.JSON.parse(json.dumps({'operation':'close','handle':str(h)})))
r['closed']=str(js.virtualFSRequest(js.JSON.parse(json.dumps({'operation':'read','handle':str(h),'offset':'0','length':1}))).errno)
try:Path('/lib/forbidden-write').write_bytes(b'bad');raise AssertionError('system write allowed')
except OSError as e:assert e.errno==errno.EROFS
Path('/workspace/published.txt').write_text('old-content')
Path('/workspace/staged.txt').write_text('new-content')
os.replace('/workspace/staged.txt','/workspace/published.txt')
assert Path('/workspace/published.txt').read_text()=='new-content'
assert not Path('/workspace/staged.txt').exists()
r.update(numpy=np.__version__,sympy=sp.__version__,yaml=yaml.__version__)
json.dumps(r)
"""#
    #endif
}

nonisolated private extension Data {
    func flatMapJSON() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: self) as? [String: Any] else { throw NSError(domain: "VirtualFilesystemReport", code: 1) }; return value
    }
}
